MCloud android-slave instance
==================

MCloud is dockerized QA infrastructure for remote web access to physical devices (Android and iOS). Is is fully integrated into the [qps-infra](http://www.qps-infra.io) ecosystem and can be used for manual so automation usage.

* It is built on the top of [OpenSTF](https://github.com/openstf) with supporting iOS devices remote control.

## Contents
* [Software prerequisites](#software-prerequisites)
* [Initial setup](#initial-setup)
* [Usage](#usage)
* [License](#license)

## Software prerequisites
* Change current user uid/guid to uid=1000 and gid=1000 - (https://github.com/jenkinsci/docker)
  Note: for current user just change uid/guid inside /etc/passwd and reboot host
* Install [docker](http://www.techrepublic.com/article/how-to-install-docker-on-ubuntu-16-04/)
* Install [ansible](https://www.techrepublic.com/article/how-to-install-ansible-on-ubuntu-server-16-04/)

## Initial setup
* Pull latest [appium-device](https://cloud.docker.com/u/qaprosoft/repository/docker/qaprosoft/appium-device/tags) docker image (TODO: automate it later as part of ansible playbook script)
```
docker pull qaprosoft/appium-device:1.15
```
* Clone https://github.com/qaprosoft/infrappium repo
```
git clone https://github.com/qaprosoft/infrappium
```
* Update roles/devices/vars/main.yml:
  * Update stf_private_host and stf_public_host using the actual value from MCloud master setup. Physically android-slave can be located on the same Linux server where STF master and QPS-Infra are deployed
  * Update selenium_hub_host and selenium_hub_port values. By default we have values for the schema when qps-infra is deployed on the same server (selenium-hub container name)
  * Declare/whitelist all Android devices using structure below
```
stf_private_host: 192.168.88.10
stf_public_host: stf.mydomain.com
selenium_hub_host: selenium-hub
selenium_hub_port: 4444
devices:
  - id: 085922ed01829ce3
    name: Nexus_5
    adb_port: 5038
    min_port: 7401
    max_port: 7410
    proxy_port: 9000
  - id: 0186a5f28f9837e9
    name: Nexus_4
    adb_port: 5039
    min_port: 7411
    max_port: 7420
    proxy_port: 9001
```
   * Note: Make sure to provide valid devices udid values
   * Name value will be used for registration this device in STF (it is recommened to avoid special symbols and spaces)
   * Provide unique adb port values for each device as they will be shared to the master Linux server
   * Provide unique range of 10 ports for each Android device. Those ports should be accessible from client's browser sessions otherwise gray screen is displayed or "adb connect" doesn't work.
   * Provide unique number of proxy_port per each device (they can be used in integration with Carina traffic sniffering fucntionality: http://qaprosoft.github.io/carina/proxy/)
 * Run ansible-playbook script to install all kind of prerequisites onto the system:
```
ansible-playbook -vvv -i hosts devices.yml
```
   * Android SDK location: /opt/android-linux-sdk
   * Appium location: /opt/appium
   * OpenCV library for FindByImage support as part of npm components
   * Container creation/removal script deployed to /usr/local/bin/device2docker
   * Udev rules with whitelisted devices are in /etc/udev/rules.d/51-android.rules
   
## Usage
* Enable developer option for each device (TODO: exact and recommended configuration steps should be provided for Android device)
* Connect Android device physically into USB direct port or through the hub
* For the 1st connection trust device picking "always trust..." on device
* Open in your browser http://<PUBLIC_IP>, authenticate yourself based on preconfigured auth system.
* Connected device should be registered automatically with ability to connect to it remotely
* Dedicated fully isolated android container is started for each device
```
docker ps -a | grep device
```
* Disconnect device from the server. In 30-60 seconds it should change state in iSTF to disconnected as well. Appropriate container is removed automatically
* <B>Note:</> adb server should not be started on the master host during devices connect/disconnect! Otherwise device will be unavailable for isolated adb inside container

## License
Code - [Apache Software License v2.0](http://www.apache.org/licenses/LICENSE-2.0)

Documentation and Site - [Creative Commons Attribution 4.0 International License](http://creativecommons.org/licenses/by/4.0/deed.en_US)
