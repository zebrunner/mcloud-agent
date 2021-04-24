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
* Install community.general ansible plugin
```
ansible-galaxy collection install community.general
```

## Initial setup
* Update `hosts` file to manage several hosts by Ansible otherwise localhost only will be configured.
* Update `roles/devices/vars/main.yml` file:
  * Set stf_provider_host to the private ip of your android slave (it should be accessible from MCloud master host)
  * Set stf_public_host using the actual value from MCloud master setup. Physically mcloud-andriod slave can be located on the same Linux server where STF is deployed
  * Set selenium_hub_host and selenium_hub_port values. By default we have values for the schema when MCloud is deployed on the same server
  * Declare/whitelist all Android devices using structure below
```
stf_provider_host: 192.168.88.10
stf_public_host: stf.mydomain.com
selenium_hub_host: mcloud-grid
selenium_hub_port: 4444
devices:
  - id: 42009c44d068b461
    name: Samsung_Galaxy_J3
    appium_port: 4723
    adb_port: 5038
    min_port: 7401
    max_port: 7410
    proxy_port: 9000
  - id: 5200e0a5e2982529
    name: Samsung_Galaxy_J5
    appium_port: 4724
    adb_port: 5039
    min_port: 7411
    max_port: 7420
    proxy_port: 9001
```
   * Note: Make sure to provide valid device udid values
   * Name value will be used for registration this device in STF (it is recommended to avoid special symbols and spaces)
   * Provide unique appium port values for each device as they will be shared to the provider Linux server
   * Provide unique adb port values for each device as they will be shared to the provider Linux server
   * Provide unique range of 10 ports for each Android device. Those ports should be accessible from client's browser sessions otherwise gray screen is displayed or "adb connect" doesn't work.
   * Provide unique number of proxy_port per each device (they can be used in integration with Carina traffic sniffering fucntionality: http://qaprosoft.github.io/carina/proxy/)
 * Run ansible-playbook script to download required components and setup udev rules:
```
ansible-playbook -vvv -i hosts devices.yml
```
 > To provide extra arguments including sudo permissions you can use
```
ansible-playbook -vvv -i hosts --user=USERNAME --extra-vars "ansible_sudo_pass=PSWD ssl_crt=/home/ubuntu/ssl.crt ssl_key=/home/ubuntu/ssl.key" devices.yml
```
   * Container creation/removal script deployed to /usr/local/bin/device2docker
   * Udev rules with whitelisted devices are in /etc/udev/rules.d/51-android.rules
   * Whitelisted devices custom properties are in /usr/local/bin/devices.txt
   
## Usage
* Enable developer option for each device (TODO: exact and recommended configuration steps should be provided for Android device)
* Connect Android device physically into USB direct port or through the hub
* For the 1st connection trust device picking "always trust..." on device
* Open in your browser http://<PUBLIC_IP>, authenticate yourself based on preconfigured auth system.
* Connected device should appear automatically in iSTF with ability to use it remotely
* Dedicated fully isolated android container is started per each device
```
docker ps -a | grep device
```
* Disconnect device from the server. In 30-60 seconds it should change state in iSTF to disconnected as well. Appropriate container is removed automatically
* <B>Note:</B> adb server should not be started on the master host during devices connect/disconnect! Otherwise device will be unavailable for isolated adb inside container

## License
Code - [Apache Software License v2.0](http://www.apache.org/licenses/LICENSE-2.0)

Documentation and Site - [Creative Commons Attribution 4.0 International License](http://creativecommons.org/licenses/by/4.0/deed.en_US)
