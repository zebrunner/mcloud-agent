Zebrunner Device Farm (Android and iOS agent)
==================

Feel free to support the development with a [**donation**](https://www.paypal.com/donate?hosted_button_id=JLQ4U468TWQPS) for the next improvements.

<p align="center">
  <a href="https://zebrunner.com/"><img alt="Zebrunner" src="https://github.com/zebrunner/zebrunner/raw/master/docs/img/zebrunner_intro.png"></a>
</p>

## Hardware requirements

|                         	| Requirements                                                     	|
|:-----------------------:	|------------------------------------------------------------------	|
| <b>Operating System</b> 	| Ubuntu 16.04, 18.04, 20.04, 21.04 <br>Linux CentOS 7+<br>Amazon Linux2|
| <b>       CPU      </b> 	| 8+ Cores                                                         	|
| <b>      Memory    </b> 	| 32 Gb RAM                                                        	|
| <b>    Free space  </b> 	| SSD 128Gb+ of free space                                         	|

## Software prerequisites
* Install docker ([Ubuntu 16.04](https://www.digitalocean.com/community/tutorials/how-to-install-and-use-docker-on-ubuntu-16-04), [Ubuntu 18.04](https://www.digitalocean.com/community/tutorials/how-to-install-and-use-docker-on-ubuntu-18-04), [Ubuntu 20.04](https://www.digitalocean.com/community/tutorials/how-to-install-and-use-docker-on-ubuntu-20-04), [Amazon Linux 2](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/docker-basics.html), [Redhat/Cent OS](https://www.cyberciti.biz/faq/install-use-setup-docker-on-rhel7-centos7-linux/))
* Install 2.9.6+ ansible ([Ubuntu 16.04](https://www.digitalocean.com/community/tutorials/how-to-install-and-configure-ansible-on-ubuntu-16-04), [Ubuntu 18.04](https://www.digitalocean.com/community/tutorials/how-to-install-and-configure-ansible-on-ubuntu-18-04), [Ubuntu 20.04](https://www.digitalocean.com/community/tutorials/how-to-install-and-configure-ansible-on-ubuntu-20-04))
* Install and start usbmuxd service
  > make sure to adjust order and made usbmuxd service started before docker!

## Initial setup
* Run `./zebrunner.sh setup` script
* Update `roles/devices/vars/main.yml` file according to the obligatory/optional comments inside.
  > Register all whitelisted Android and iOS devices with their udids
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
  ansible-playbook -vvv -i hosts --user=USERNAME --extra-vars "ansible_sudo_pass=PSWD" devices.yml
  ```
 * Devices management script deployed to /usr/local/bin/zebrunner-farm
 * Udev rules with whitelisted devices are in /etc/udev/rules.d/90_mcloud.rules
 * Whitelisted devices properties are in /usr/local/bin/mcloud-devices.txt
   
## Usage

### Android devices
* Enable Developer Option and USB Debugging for each Android device
* Connect Android device physically into USB direct port or through the hub.
* For the 1st connection trust device picking "always trust..." on device.

### iOS devices

You need supervise iOS device to be able to accept "Trust" alert messages automatically during reconnect.

For non supervised iOS device just click "Trust" (supervise setting can be skipped)

#### [Optional] Supervise device 

 
   ##### Erase all contents and exit from icloud id on iOS device:

- Go to > Settings > General > Transfer or Reset iPhone.
- Tap Erase All Content and Settings.
- When iPhone restarts with all content and settings erased, you have the option to set up iPhone as new.
  
1. Connect device to Mac OS (Trust manually)
2. Open Apple Configurator 2
3. Pick Apple Configurator -> Preferences -> Organizations -> Create new Organizations
   -> Fill in all fields
4. Click to connected iOS device and choose Prepare
5. Obligatory actions to provision:
- Manual configuration
- Supervise devices
- Allow devices to pair with other computer
6. Click Next
7. Select: "Do not enroll in MDM Enroll"  in MDM Server, click Next
8. Select your organization
9. Select "Show all steps" on Configure iOS Setup Assistant
10. Click Prepare
11. Export Supervision Identity p12 file
12. Put p12 file to mcloud-agent and share via P12FILE and P12PASSWORD variables in roles/devices/vars/main.yml file
> Supervided devices after physical reconnect should be trusted automatically.

13. Set up iPhone as new.

#### Automation steps
* Enable Settings -> Developer -> Enable UI Automation
* Settings -> Safari -> Advanced -> Web Inspector
* Enable Siri


#### Prepare WebDriverAgent.ipa file

You need an Apple Developer account to sign and build **WebDriverAgent**

1. Open **WebDriverAgent.xcodeproj** in Xcode.
2. Ensure a team is selected before building the application. To do this go to: *Targets* and select each target one at a time. There should be a field for assigning teams certificates to the target.
3. Remove your **WebDriverAgent** folder from *DerivedData* and run *Clean build folder* (just in case)
4. Next build the application by selecting the *WebDriverAgentRunner* target and build for *Generic iOS Device*. Run *Product => Build for testing*. This will create a *Products/Debug-iphoneos* in the specified project directory.  
 *Example*: **/Users/<username>/Library/Developer/Xcode/DerivedData/WebDriverAgent-dzxbpamuepiwamhdbyvyfkbecyer/Build/Products/Debug-iphoneos**
5. Go to the "Products/Debug-iphoneos" directory and run:
 **mkdir Payload**
6. Copy the WebDriverAgentRunner-Runner.app to the Payload directory:
 **cp -r WebDriverAgentRunner-Runner.app Payload**
7. Finally zip up the project as an ipa file:
 **zip -r WebDriverAgent.ipa Payload**
8. Get the WebDriverAgent.ipa file, put it onto the corrent host and share via WDA_IPA_PATH variable in roles/devices/vars/main.yml file


### SmartTestFarm
* Open in your browser http://<PUBLIC_IP>/stf, authenticate yourself based on preconfigured auth system.
* Connected device should be available in STF.
* Disconnect device from the server. Device containers removed asap, in 15-30 sec device should change state in STF to disconnected as well.
* Use different commands from `./zebrunner.sh start/stop/restart` to manage devices
  > Run `./zebrunner.sh` to see available options

## Troubleshooting
Follow the below algorithm to identify any configuration issues with MCloud agent:
* Enable the debug log level for udev rules: `sudo udevadm control --log-priority=debug`
* Inspect syslog to check if the `zebrunner-farm` shell script executed on every whitelisted device is able to connect/disconnect:
  ```
  tail -f /var/log/syslog | grep zebrunner-farm
  ```
* If there are no updates during connection/disconnection, please, verify the correctness of:
  * device udid values
  * presence of `/usr/local/bin/zebrunner-farm`
  * correctness of `/usr/local/bin/mcloud-devices.txt` and `/etc/udev/rules.d/90_mcloud.rules` files
* Read carefully the `zebrunner-farm` output in syslog to identify the exact failure during containers creation
* Analyze device container logs if the status is not `healthy`:
  ```
  docker ps -a | grep device
  // appium and WebDriverAgent for iOS container:
  docker logs -f device-<Name>-<udid>-appium
  // STF provider container:
  docker logs -f device-<Name>-<udid>
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
