#!/bin/bash

go_version=""

go_dir=/usr/local

##################################################
##################################################
##################   input   #####################
##################################################
##################################################


while test $# -gt 0; do
  case "$1" in
   --go-version)
      go_version=$2
      shift
      shift
      ;;

   --go-dir)
      go_dir=$2
      shift
      shift
      ;;

   --help | -h)
      echo "
This scripts is used to prepare a fresh setup for using the scripts used in https://github.com/Mellanox/kubernetes-ci,\
it do the following:
    - install golang
    - install docker
    - disable swap
    - configure /etc/sysctl.conf
    - configure /etc/hosts
    - install yq

options:

    --go-version)			Go version to download, if not specified, the script will try to get the latest version.

    --go-dir)				Where to download and install the go.
"
      exit 0
      ;;
   
   *)
      echo "No such option!!"
      echo "Exitting ...."
      exit 1
  esac
done

get_latest_go(){
    wget -qO- https://golang.org/dl/ | grep -oE 'go(([0-9]+.)+[0-9])' | head -n 1 | grep -o [0-9\.]*
}

golang_install(){
    echo ""
    echo "installing go in $go_dir"
 
    go_tar=go"$go_version".linux-amd64.tar.gz
    yum install wget  git -y > /dev/null
 
    if [[ ! "`go version`" =~ "$go_version" ]]
    then
       if [[ ! -f "$go_dir"/"$go_tar" ]]
       then
           if [[ ! `wget -S --spider https://dl.google.com/go/"$go_tar"  2>&1 | grep 'HTTP/1.1 200 OK'` ]]
           then
               echo "ERROR: No go version $go_version upstream!"
               echo "Exiting...."
               exit 1
           fi
           sudo wget https://dl.google.com/go/$go_tar -P "$go_dir"
       fi
 
        sudo rm -rf "$go_dir"/go
        sudo tar -C /usr/local -xzf "$go_dir"/"$go_tar"

        sed -i ';/usr/local/go/bin;d' ~/.bashrc
        echo 'PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
        source ~/.bashrc
 
        if [[ -z "$(go version)" ]]; then
            echo "Failed to install go!"
            return 1
        fi
    else
        echo "go is already version $go_version!"
    fi

    echo ""
    echo "Successfuly installed GO."
}

docker_install(){
    local distro=$(get_distro)
    local_status=0

    echo ""
    echo "Installing Docker ...."

    if [[ "$distro" == "centos" ]];then
        yum install -y yum-utils > /dev/null
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        yum install -y docker-ce docker-ce-cli containerd.io > /dev/null
    elif [[ "$distro" == "ubuntu" ]];then
        sudo apt-get -y update > /dev/null
        sudo apt-get -y install apt-transport-https ca-certificates curl gnupg-agent software-properties-common > /dev/null
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
        sudo add-apt-repository -y "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
        sudo apt-get -y update > /dev/null
        sudo apt-get -y install docker-ce docker-ce-cli containerd.io > /dev/null
    else
        echo "Unknown distro for installing docker."
        return 1
    fi

    sudo systemctl start docker
    let local_status=$local_status+$?
    sudo systemctl enable docker
    let local_status=$local_status+$?

    echo ""
    echo "Finished installing Docker."

    return $local_status
}

disable_swap(){
    echo ""
    echo "Turing off swap ...."

    swapoff -a
    if [[ "$?" != "0" ]];then
        echo "Unable to turn off swap!"
        return 1
    fi

    swap_line_numbers="$(grep -x -n "[^#]*swap.*" /etc/fstab | cut -d":" -f 1)"
    if [[ -n $swap_line_numbers ]]
    then
        for line_number in $swap_line_numbers;
        do
           sed -i "$line_number s/^/\#/g" /etc/fstab
        done
     fi

     echo ""
     echo "Finished turning swap off!"
}

configure_ipv4_confs(){
    echo ""
    echo "Configuring /etc/sysctl.conf ...."

    sed -i '/^net.ipv4.ip_forward=/d' /etc/sysctl.conf
    sed -i '/^net.bridge.bridge-nf-call-iptables=/d' /etc/sysctl.conf

    echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    echo 'net.bridge.bridge-nf-call-iptables=1' >> /etc/sysctl.conf

    modprobe br_netfilter

    sysctl -p
    if [[ "$?" != "0" ]];then
        echo "Error configuring the net confs!"
        return 1
    fi

    echo ""
    echo "Finished configuring /etc/sysctl.conf!"
}

configure_hostname(){
    echo ""
    echo "Configuring /etc/hosts based on <$(hostname -i) $(hostname -f) $(hostname)> ...."

    ip_add=$(hostname -i)
    full_hostname=$(hostname -f)

    sed -i "/$(hostname)/d" /etc/hosts
    sed -i "/$ip_add/d" /etc/hosts

    echo "$ip_add $full_hostname $(hostname)" >> /etc/hosts
}

get_distro(){
    grep ^NAME= /etc/os-release | cut -d'=' -f2 -s | tr -d '"' | tr [:upper:] [:lower:] | cut -d" " -f 1
}

validate_variables(){
    if [[ -z "$go_version" ]];then
        echo "No go version specified!"
        go_version=$(get_latest_go)
        echo "Assuming latest go: $go_version ...."
    fi
    
    if [[ -z "$go_dir" ]];then
        echo "Empty go_dir!"
        echo "Setting go_dir to /usr/local"
        go_dir=/usr/local
    fi
}

install_yq(){
    echo ""
    echo "Installing yq ...."

    local yq_link='https://github.com/mikefarah/yq/releases/download/3.4.0/yq_linux_amd64'

    if ! command -v yq &> /dev/null
    then
        if [[ ! `wget -S -O - $yq_link  2>&1 | grep 'HTTP/1.1 200 OK'` ]]
        then
            echo "yq not found upstream at $yq_link!"
            echo "Exiting...."
            exit 1
        fi

        rm -f /usr/bin/yq
        sudo wget $yq_link -O /usr/bin/yq
        sudo chmod +x /usr/bin/yq

        if [[ -z "$(yq -V)" ]]; then
            echo "Failed to install yq!"
            return 1
        fi
    else
        echo "yq is already present in the machine!"
    fi

    echo ""
    echo "Finished installing yq!"

    return 0
}

main(){
    status=0

    validate_variables

    golang_install
    let status=$status+$?

    docker_install
    let status=$status+$?

    disable_swap
    let status=$status+$?

    configure_ipv4_confs
    let status=$status+$?

    configure_hostname
    let status=$status+$?

    install_yq
    let status=$status+$?

    return $status
}

main

status="$?"
if [[ "$status" != "0" ]];then
    echo "Error in preparing the setup!!!"
else
    echo ""
    echo "Preparing the setup succeed!"
    echo ""
    echo "source the ~/.bashrc to load the new PATH variable."
    echo ""
    echo "    #source ~/.bashrc"
    echo ""
fi

exit $status
