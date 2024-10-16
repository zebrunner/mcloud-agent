Zebrunner Device Farm (Android and iOS agent)
==================

Feel free to support the development with a [**donation**](https://www.paypal.com/donate/?hosted_button_id=MNHYYCYHAKUVA) for the next improvements.

<p align="center">
  <a href="https://zebrunner.com/"><img alt="Zebrunner" src="https://github.com/zebrunner/zebrunner/raw/master/docs/img/zebrunner_intro.png"></a>
</p>

## Hardware requirements

|                         	| Requirements                                                     	|
|:-----------------------:	|------------------------------------------------------------------	|
| <b>Operating System</b> 	| Ubuntu 16.04, 18.04, 20.04, 21.04, 22.04 <br>Linux CentOS 7+<br>Amazon Linux2<br> MacOS (Ventura)|
| <b>       CPU      </b> 	| 8+ Cores                                                         	|
| <b>      Memory    </b> 	| 32 Gb RAM                                                        	|
| <b>    Free space  </b> 	| SSD 128Gb+ of free space                                         	|

## Software prerequisites
* Install docker ([Ubuntu 16.04](https://www.digitalocean.com/community/tutorials/how-to-install-and-use-docker-on-ubuntu-16-04), [Ubuntu 18.04](https://www.digitalocean.com/community/tutorials/how-to-install-and-use-docker-on-ubuntu-18-04), [Ubuntu 20.04](https://www.digitalocean.com/community/tutorials/how-to-install-and-use-docker-on-ubuntu-20-04), [Amazon Linux 2](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/docker-basics.html), [Redhat/Cent OS](https://www.cyberciti.biz/faq/install-use-setup-docker-on-rhel7-centos7-linux/)).
* Install 2.9.6+ ansible ([Ubuntu 16.04](https://www.digitalocean.com/community/tutorials/how-to-install-and-configure-ansible-on-ubuntu-16-04), [Ubuntu 18.04](https://www.digitalocean.com/community/tutorials/how-to-install-and-configure-ansible-on-ubuntu-18-04), [Ubuntu 20.04](https://www.digitalocean.com/community/tutorials/how-to-install-and-configure-ansible-on-ubuntu-20-04)).
* MacOS: install and authorize [go-ios](https://github.com/danielpaulus/go-ios) utility 1.0.121+
* MacOS: install socat utility to share usbmuxd websocket into the device containers
  > valid path to socat binary should be `/usr/local/bin/socat`
* MacOS: install jq utility

## Clone and setup
* Clone mcloud-agent repository and execute setup procedure
  ```
  git clone https://github.com/zebrunner/mcloud-agent.git
  cd mcloud-agent
  ./zebrunner.sh setup
  ```

## Run ansible playbook
* [Optional] To enable opencv support append `-opencv5.6.0` postfix to the `APPIUM_VERSION` in the ./defaults/main.yml:
  ```
  APPIUM_VERSION: 2.0-opencv5.6.0
  ```
  > Full list of supported appium+opencv images can be found here: https://gallery.ecr.aws/zebrunner/appium

### Linux OS
* update `roles/devices/vars/main.yml` file according to the obligatory/optional comments inside.
  > Register all whitelisted Android and iOS devices with their udids!
* Run ansible-playbook script to download the required components and set up udev rules:
  ```bash
  ./zebrunner.sh ansible
  ```
  > To reregister the devices list only, you can use the following command:
  ```bash
  ./zebrunner.sh ansible devices
  ```
  > To provide extra arguments including sudo permissions, you can use the below command:
  ```bash
  ./zebrunner.sh ansible --user=USERNAME --extra-vars "ansible_sudo_pass=PSWD"
  ```
 * Devices management script is deployed to /usr/local/bin/zebrunner-farm.
 * Udev rules with whitelisted devices are in /etc/udev/rules.d/90_mcloud.rules.
 * Whitelisted devices properties are in /usr/local/bin/mcloud-devices.txt.
 * Usbmuxd service is stopped and masked (disabled).
 * [Optional] Register`@reboot /usr/local/bin/zebrunner-farm restart` via crontab to forcibly restart containers on reboot
 * [Optional] Increased `fs.inotify.max_user_instances` to workaround [#328](https://github.com/zebrunner/mcloud-agent/issues/328)
   > `sudo sysctl fs.inotify.max_user_instances=2048`

### Mac OS
* update `roles/mac-devices/vars/main.yml` file according to the obligatory/optional comments inside.
  > Register all whitelisted iOS devices (phones, tablets or TVes) with their udids!
  > Important! Only iOS devices supported on MacOS!
* Run ansible-playbook script to download the required components and set up udev rules:
  ```bash
  ./zebrunner.sh ansible
  ```
  > To reregister the devices list only, you can use the following command:
  ```bash
  ./zebrunner.sh ansible devices
  ```
  > To provide extra arguments including sudo permissions, you can use the below command:
  ```bash
  ./zebrunner.sh ansible --user=USERNAME --extra-vars "ansible_sudo_pass=PSWD"
  ```
 * Devices management script is deployed to /usr/local/bin/zebrunner-farm.
 * Whitelisted devices properties are in /usr/local/bin/mcloud-devices.txt.
 * Deployed and loaded $HOME/Library/LaunchAgents/ZebrunnerUsbmuxd.plist to share usbmuxd into the device containers
 * Deployed $HOME/Library/LaunchAgents/ZebrunnerDevicesListener.plist to load and manage iOS devices connect/disconnect automatically

   
## Usage

### Android devices
* Enable the Developer Option and USB Debugging for each Android device.
* Connect an Android device physically to a USB direct port or through the hub.
* For the 1st connection, trust the device by picking "always trust..." on the device.

### iOS devices

#### Automation steps

* Enable Settings -> Developer -> Enable UI Automation.
* Settings -> Safari -> Advanced -> Web Inspector.
* Enable Siri.
* Disable screen lock:
  > Phone and Tablet: Settings->Lock screen->Turn display off when inactive->select Never

  > Apple TV: Settings->General->Sleep after->Select never

#### Build WebDriverAgent.ipa

You need an Apple Developer account to sign in and build **WebDriverAgent**.

1. Open **WebDriverAgent.xcodeproj** in Xcode.
2. Ensure a team is selected before building the application. To do this, go to *Targets* and select each target (one at a time). There should be a field for assigning team certificates to the target.
3. Remove your **WebDriverAgent** folder from *DerivedData* and run *Clean build folder* (just in case).
4. Build the application by selecting the *WebDriverAgentRunner* target and build for *Generic iOS Device*. Run *Product -> Build for testing*. This will create a *Products/Debug-iphoneos* in the specified project directory.  
 *Example*: **/Users/$USER/Library/Developer/Xcode/DerivedData/WebDriverAgent-dzxbpamuepiwamhdbyvyfkbecyer/Build/Products/Debug-iphoneos**
5. Go to the "Products/Debug-iphoneos" directory and run:
 **mkdir Payload**
6. Copy the WebDriverAgentRunner-Runner.app to the Payload directory:
 **cp -r WebDriverAgentRunner-Runner.app Payload**
7. Finally, zip up the project as an *.ipa file:
 **zip -r WebDriverAgent.ipa ./Payload**
   > Make sure to specify relative `./Payload` to archive only Payload folder content 
8. Share built ipa via WDA_FILE variable in roles/devices/vars/main.yml file.
   > to override WDA_FILE artifacts per each device use `wda_file` and `wda_bundleid` iOS device properties and re-execute ansible playbook.


### SmartTestFarm
* Open in your browser http://<PUBLIC_IP>/stf, authenticate yourself based on preconfigured auth system.
* The connected device should be available in STF.
* Disconnect the device from the server. Device containers will be removed asap, then, in 15-30 sec, the device should change the state in STF to disconnected as well.
* Use different commands from `./zebrunner.sh start/stop/restart` to manage the devices.
  > Run `./zebrunner.sh` to see available options.

## Troubleshooting
Follow the below algorithm to identify any configuration issues with MCloud agent:
* Enable the debug log level for udev rules: `sudo udevadm control --log-priority=debug`.
* Inspect syslog to check if the `zebrunner-farm` shell script executed on every whitelisted device is able to connect/disconnect:
  ```
  tail -f /var/log/syslog | grep zebrunner-farm
  ```
* If there are no updates during connection/disconnection, please, verify the correctness of:
  * device udid values,
  * presence of `/usr/local/bin/zebrunner-farm`,
  * correctness of `/usr/local/bin/mcloud-devices.txt` and `/etc/udev/rules.d/90_mcloud.rules` files.
* Read carefully the `zebrunner-farm` output in syslog to identify the exact failure during containers creation.
* Analyze device container logs if the status is not `healthy`:
  ```
  docker ps -a | grep device
  // appium and WebDriverAgent for iOS container:
  docker logs -f device-<Name>-<udid>-appium
  // STF provider container:
  docker logs -f device-<Name>-<udid>
  // artifacts uploader container:
  docker logs -f device-<Name>-<udid>-uploader
  ```
* If you have any problems with running ansible:
  * Make sure you have sudo access and try to run ansible with sudo permissions.
  * Try to rub ansible commands manually (`<devices_file>` name usually are `mac-devices` or `devices`)
 
  > To download the required components and set up udev rules:
  ```
  ansible-playbook -vvv -i hosts <devices_file>.yml
  ```
  > To reregister the devices list only, you can use the following command:
  ```
  ansible-playbook -vvv -i hosts <devices_file>.yml --tag registerDevices
  ```
  > To provide extra arguments including sudo permissions, you can use the below command:
  ```
  ansible-playbook -vvv -i hosts --user=USERNAME --extra-vars "ansible_sudo_pass=PSWD" <devices_file>.yml
  ```

## Documentation and free support
* [Zebrunner PRO](https://zebrunner.com)
* [Zebrunner CE](https://zebrunner.github.io/community-edition)
* [Zebrunner Reporting](https://zebrunner.com/documentation)
* [Carina Guide](http://zebrunner.github.io/carina)
* [Demo Project](https://github.com/zebrunner/carina-demo)
* [Telegram Channel](https://t.me/zebrunner)

## License
Code - [Apache Software License v2.0](http://www.apache.org/licenses/LICENSE-2.0)

Documentation and Site - [Creative Commons Attribution 4.0 International License](http://creativecommons.org/licenses/by/4.0/deed.en_US)
