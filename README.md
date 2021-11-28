Zebrunner Device Farm (Android slave)
==================

## Contents
* [Software prerequisites](#software-prerequisites)
* [Initial setup](#initial-setup)
* [Usage](#usage)
* [License](#license)

## Software prerequisites
* Install docker ([Ubuntu 16.04](https://www.digitalocean.com/community/tutorials/how-to-install-and-use-docker-on-ubuntu-16-04), [Ubuntu 18.04](https://www.digitalocean.com/community/tutorials/how-to-install-and-use-docker-on-ubuntu-18-04), [Ubuntu 20.04](https://www.digitalocean.com/community/tutorials/how-to-install-and-use-docker-on-ubuntu-20-04), [Amazon Linux 2](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/docker-basics.html), [Redhat/Cent OS](https://www.cyberciti.biz/faq/install-use-setup-docker-on-rhel7-centos7-linux/))
* Install ansible ([Ubuntu 16.04](https://www.digitalocean.com/community/tutorials/how-to-install-and-configure-ansible-on-ubuntu-16-04), [Ubuntu 18.04](https://www.digitalocean.com/community/tutorials/how-to-install-and-configure-ansible-on-ubuntu-18-04), [Ubuntu 20.04](https://www.digitalocean.com/community/tutorials/how-to-install-and-configure-ansible-on-ubuntu-20-04))

## Initial setup
* Update `hosts` file to manage several hosts by Ansible otherwise localhost only will be configured.
* Update `roles/devices/vars/main.yml` file according to the obligatory/optional comments inside.
* Run ansible-playbook script to download required components and setup udev rules:
  ```
  ansible-playbook -vvv -i hosts devices.yml
  ```
 > To reregister devices list only you can use command:
  ```
  ansible-playbook -vvv -i hosts devices.yml --tag registerDevices
  ```
 
 > To provide extra arguments including sudo permissions you can use
```
ansible-playbook -vvv -i hosts --user=USERNAME --extra-vars "ansible_sudo_pass=PSWD SSL_CRT=/home/ubuntu/ssl.crt SSL_KEY=/home/ubuntu/ssl.key" devices.yml
```
   * Devices management script deployed to /usr/local/bin/zebrunner-farm
   * Udev rules with whitelisted devices are in /etc/udev/rules.d/51-android.rules
   * Whitelisted devices custom properties are in /usr/local/bin/devices.txt
   
## Usage
* Enable developer option for each device (TODO: exact and recommended configuration steps should be provided for Android device)
* Connect Android device physically into USB direct port or through the hub
* For the 1st connection trust device picking "always trust..." on device
* Open in your browser http://<PUBLIC_IP>/stf, authenticate yourself based on preconfigured auth system.
* Connected device should appear automatically in STF with ability to use it remotely
* Dedicated fully isolated android container is started per each device
```
docker ps -a | grep device
```
* Disconnect device from the server. In 30-60 seconds it should change state in STF to disconnected as well. Appropriate container is removed automatically.
* <B>Note:</B> adb server should not be started on the master host during devices connect/disconnect! Otherwise devices will be unavailable inside isolated container
* To recreate container you can execute `zebrunner-farm recreate <deviceContainerName>`

## License
Code - [Apache Software License v2.0](http://www.apache.org/licenses/LICENSE-2.0)

Documentation and Site - [Creative Commons Attribution 4.0 International License](http://creativecommons.org/licenses/by/4.0/deed.en_US)
