# Zebrunner Device Farm (Android and iOS agent)

The agent runs the containers of every device of a Linux or macOS server: the connector (the only point of contact with
the device), STF, Appium and the artifacts uploader. The connector takes the device whatever its connection is, the STF and
Appium containers always take adb, usbmuxd and WebDriverAgent from it.

| Device | Connection | Linux | macOS |
| --- | --- | --- | --- |
| Android phone, tablet, TV | `usb` | adb server of the connector (USB passed in) | adb server of the host (a launch agent), the connector forwards the device to its own adb server |
| Android | `wireless` | adb connect of the connector | adb connect of the connector |
| Redroid emulator | `redroid` | the emulator container of the device, the kernel needs binder | only with a docker kernel with binder (not Docker Desktop) |
| iPhone, iPad, Apple TV HD | `usb` | usbmuxd of the connector | usbmuxd of the host, the connector installs and starts WebDriverAgent over it |
| iPhone, iPad, Apple TV over Wi-Fi | `wireless` | netmuxd of the connector at `address` (paired over USB first) | usbmuxd of the host (paired with the Mac) |
| iOS, iPadOS, tvOS simulator | `simulator` | - | the connector runs `xcrun simctl` of the host over ssh |
| any iOS device whose WebDriverAgent is started by another tool (e.g. Apple TV 4K with tvOS 17+) | `proxy` | the connector relays WebDriverAgent of `address` | the same |

iOS 17.0 - 17.4.0 has a tunnel over the USB of a Linux host only (go-ncm); with the other connections WebDriverAgent of such a
device must be started outside the containers.

Feel free to support the development with a [**donation**](https://www.paypal.com/donate/?hosted_button_id=MNHYYCYHAKUVA) for the next improvements.

<p style="text-align: center">
  <a href="https://zebrunner.com/"><img alt="Zebrunner" src="https://github.com/zebrunner/zebrunner/raw/master/docs/img/zebrunner_intro.png"></a>
</p>

## Hardware requirements

| | Requirements |
| --- | --- |
| <b>Operating System</b> | Ubuntu 16.04, 18.04, 20.04, 21.04, 22.04 <br>Linux CentOS 7+<br>Amazon Linux2<br> macOS 13 (Ventura)+, Apple Silicon or Intel |
| <b>       CPU      </b> | 8+ Cores |
| <b>      Memory    </b> | 32 Gb RAM |
| <b>    Free space  </b> | SSD 128Gb+ of free space |

## Software prerequisites

- Install docker: [Docker Engine](https://docs.docker.com/engine/install/) on Linux ([Amazon Linux 2](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/docker-basics.html)), [Docker Desktop](https://docs.docker.com/desktop/setup/install/mac-install/) on macOS.
- Install [ansible](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html) 2.10+ (the playbooks use `ansible.builtin` module names, tested with ansible-core 2.21), e.g. `pip install ansible-core`.
- macOS: install and authorize [go-ios](https://github.com/danielpaulus/go-ios) utility 1.0.121+, it installs WebDriverAgent on the devices (see [Build WebDriverAgent.ipa](#build-webdriveragentipa))
- macOS: install socat utility to share usbmuxd websocket into the device containers
  > valid path to socat binary should be `/usr/local/bin/socat`
  > on Apple Silicon Homebrew installs it to `/opt/homebrew/bin/socat`, link it: `sudo ln -s /opt/homebrew/bin/socat /usr/local/bin/socat`
- macOS: install jq utility

## Clone and setup

- Clone mcloud-agent repository and execute setup procedure

  ```bash
  git clone https://github.com/zebrunner/mcloud-agent.git
  cd mcloud-agent
  ./zebrunner.sh setup
  ```

## Run ansible playbook

- [Optional] To enable opencv support append `-opencv5.6.0` postfix to the `APPIUM_VERSION` in the ./defaults/main.yml:

  ```yaml
  APPIUM_VERSION: 2.1-opencv5.6.0
  ```

  > Full list of supported appium+opencv images can be found here: <https://gallery.ecr.aws/zebrunner/appium>

### Linux OS

- update `roles/devices/vars/main.yml` file according to the obligatory/optional comments inside.
  > Register all whitelisted Android and iOS devices with their udids!
  > The deploy validates the devices: obligatory settings, unique ids and names, and host ports (`appium_port`, `min_port`-`max_port`) not shared by devices.
- Run ansible-playbook script to download the required components and set up udev rules:

  ```bash
  ./zebrunner.sh ansible
  ```

  > To reregister the devices list only, you can use the following command:

  ```bash
  ./zebrunner.sh ansible devices
  ```

  > To provide extra arguments, e.g. another user, you can use the below command. The sudo password is asked interactively: do not pass it in the command line, where it stays in the shell history and is visible in the processes list.

  ```bash
  ./zebrunner.sh ansible --user=USERNAME
  ```

- Devices management script is deployed to /usr/local/bin/zebrunner-farm.
- Udev rules with whitelisted devices are in /etc/udev/rules.d/90_mcloud.rules.
- Whitelisted devices properties are in /usr/local/bin/mcloud-devices.txt.
- Usbmuxd service is stopped and masked (disabled).
- Wireless, Redroid and proxy devices have no udev rules: `zebrunner-farm start` creates their containers.
- Redroid: load binder of the kernel, e.g. `sudo modprobe binder_linux devices=binder,hwbinder,vndbinder` (and in `/etc/modules-load.d` to keep it after a reboot).
- [Optional] Register`@reboot /usr/local/bin/zebrunner-farm restart` via crontab to forcibly restart containers on reboot
- [Optional] Increased `fs.inotify.max_user_instances` to workaround [#328](https://github.com/zebrunner/mcloud-agent/issues/328)
  > `sudo sysctl fs.inotify.max_user_instances=2048`

### Mac OS

- update `roles/mac-devices/vars/main.yml` file according to the obligatory/optional comments inside.
  > Register all whitelisted Android and iOS devices (phones, tablets, TVs or simulators) with their udids and connections!
  > The deploy validates the devices: obligatory settings, unique ids and names, the connections, host ports (`appium_port`, `min_port`-`max_port`, `wda_port` and `mjpeg_port` of the simulators, `adb_port` of the USB Android devices) not shared by devices.
- Run ansible-playbook script to download the required components and set up launchd agents:

  ```bash
  ./zebrunner.sh ansible
  ```

  > To reregister the devices list only, you can use the following command:

  ```bash
  ./zebrunner.sh ansible devices
  ```

  > To provide extra arguments, e.g. another user, you can use the below command. The sudo password is asked interactively: do not pass it in the command line, where it stays in the shell history and is visible in the processes list.

  ```bash
  ./zebrunner.sh ansible --user=USERNAME
  ```

- Devices management script is deployed to /usr/local/bin/zebrunner-farm.
- Whitelisted devices properties are in /usr/local/bin/mcloud-devices.txt.
- Deployed and loaded $HOME/Library/LaunchAgents/ZebrunnerUsbmuxd.plist to share usbmuxd into the device containers
- USB Android devices: deployed and loaded $HOME/Library/LaunchAgents/ZebrunnerAdb.plist, the adb server of the host (`brew install android-platform-tools`); the connectors take the devices from it, the containers of a USB Android device are created by `zebrunner-farm start` (the devices listener handles iOS only).
- Simulators: the ssh key of the agent is generated into `ssh/id_ed25519` of the agent folder and authorized in `~/.ssh/authorized_keys` (`restrict`), turn on Remote Login (System Settings, General, Sharing) for the user. Set the simulator build of WebDriverAgent (`WDA_SIMULATOR_FILE` or `wda_file` of the device), e.g. `WebDriverAgentRunner-Build-Sim-arm64.zip` of [appium/WebDriverAgent](https://github.com/appium/WebDriverAgent/releases).
- Deployed $HOME/Library/LaunchAgents/ZebrunnerDevicesListener.plist to load and manage iOS devices connect/disconnect automatically: the devices listener (/usr/local/bin/zebrunner-device-listener and usbmuxd_watch) restarts the containers of a connected USB device and removes them on disconnect, devices reachable over Wi-Fi only are not handled by it.
- Log rotation of the devices listener log is set up in /etc/newsyslog.d/zebrunner-mcloud.conf.
- Run `zebrunner-farm start` to create the containers of the connected devices and to load the devices listener (otherwise it is loaded on the next login only).

## Agent management

`./zebrunner.sh` without arguments lists its commands:

- `setup` - prepares the agent: the `ZEBRUNNER_MCLOUD_AGENT_DIR` variable in the shell profiles and the devices settings from the example.
- `ansible [devices]` - deploys the agent, `devices` registers the devices only.
- `status` - shows the state of the agent components: tools, deployed files, launch agents.
- `backup` and `restore` - save the settings into the `backup` folder and restore them from it.
- `shutdown` - removes the devices containers, the launch agents or udev rules, the deployed files, the settings and the environment variable (asks for confirmation).
- `version` - shows the versions of the agent components.

## Usage

### Android devices

- Enable the Developer Option and USB Debugging for each Android device.
- Connect an Android device physically to a USB direct port or through the hub.
- For the 1st connection, trust the device by picking "always trust..." on the device.

### Wireless devices

- Android: enable Wireless debugging (or `adb tcpip 5555` over USB), set `connection: wireless` and `address` (the IP, the `id` by default).
- iOS on Linux: connect the device over USB once with `connection: usb` (it is paired with the farm), allow its lockdown over Wi-Fi: `docker exec device-<name>-<udid>-connector mcloud-ios wifi-connections <udid> on`, then set `connection: wireless` and `address` (its IP, a DHCP reservation is recommended) and re-run `./zebrunner.sh ansible devices`.
- iOS on macOS: pair the device with the Mac and enable "Connect via network" in Xcode, set `connection: wireless`.
- Apple TV 4K (tvOS 17+) pairs with a PIN over RemotePairing, which the containers do not support yet: start its WebDriverAgent with another tool and use `connection: proxy` with its `address`.

### iOS devices

#### Automation steps

- Enable Settings -> Developer -> Enable UI Automation.
- Settings -> Safari -> Advanced -> Web Inspector.
- Enable Siri.
- Disable screen lock:
  > Phone and Tablet: Settings -> Lock screen -> Turn display off when inactive -> select Never
  >
  > Apple TV: Settings -> General -> Sleep after -> Select never

#### Build WebDriverAgent.ipa

You need an Apple Developer account to sign in and build **WebDriverAgent**.

1. Clone **WebDriverAgent** from source you prefer. We recommend our [forked repository](https://github.com/zebrunner/WebDriverAgent) with performance improvements.

   ```bash
   git clone https://github.com/zebrunner/WebDriverAgent.git
   ```

2. Open **WebDriverAgent.xcodeproj** in Xcode.
3. Ensure a team is selected before building the application. To do this, go to *Targets* and select each target (one at a time). There should be a field for assigning team certificates to the target.
4. Remove your **WebDriverAgent** folder from *DerivedData* and run *Clean build folder* (just in case).
5. Build the application by selecting the *WebDriverAgentRunner* target and build for *Generic iOS Device*. Run *Product -> Build for testing*. This will create a *Products/Debug-iphoneos* in the specified project directory. *Example*: **/Users/$USER/Library/Developer/Xcode/DerivedData/WebDriverAgent-dzxbpamuepiwamhdbyvyfkbecyer/Build/Products/Debug-iphoneos**
6. Go to the "Products/Debug-iphoneos" directory and run: **mkdir Payload**
7. Copy the WebDriverAgentRunner-Runner.app to the Payload directory: **cp -r WebDriverAgentRunner-Runner.app Payload**
8. Finally, zip up the project as an *.ipa file: **zip -r WebDriverAgent.ipa ./Payload**
   > Make sure to specify relative `./Payload` to archive only Payload folder content
9. Share built ipa via WDA_FILE variable in roles/devices/vars/main.yml (Linux) or roles/mac-devices/vars/main.yml (macOS) file.
   > to override WDA_FILE artifacts per each device use `wda_file` and `wda_bundleid` iOS device properties and re-execute ansible playbook.
10. The device connector installs WebDriverAgent from the ipa on Linux and on macOS (over usbmuxd of the host), a WebDriverAgent started on macOS by the host is used as is.

### SmartTestFarm

- Open in your browser `http://<PUBLIC_IP>/stf`, authenticate yourself based on preconfigured auth system.
- The connected device should be available in STF.
- Disconnect the device from the server. Device containers will be removed asap, then, in 15-30 sec, the device should change the state in STF to disconnected as well.
- Use different commands from `zebrunner-farm start/stop/restart/down/status` to manage all devices, a device by udid or name, or all devices of a platform (ios/android).
  > Run `zebrunner-farm` to see available options.

## Troubleshooting

Follow the below algorithm to identify any configuration issues with MCloud agent:

- macOS: the devices listener logs into `logs/listener.log` and `logs/listener.err.log`, the usbmuxd sharing (socat) into `logs/usbmuxd-socat.log` and `logs/usbmuxd-socat.err.log` of the MCloud agent directory. `listener.log` is rotated by newsyslog (10 MB, 7 bzip2 archives, `/etc/newsyslog.d/zebrunner-mcloud.conf`). Loaded agents are shown by `launchctl list | grep zebrunner`.
- Linux: enable the debug log level for udev rules: `sudo udevadm control --log-priority=debug`.
- Linux: inspect syslog to check if the `zebrunner-farm` shell script executed on every whitelisted device is able to connect/disconnect:

  ```bash
  tail -f /var/log/syslog | grep zebrunner-farm
  ```

- If there are no updates during connection/disconnection, please, verify the correctness of:
  - device udid values,
  - presence of `/usr/local/bin/zebrunner-farm`,
  - correctness of `/usr/local/bin/mcloud-devices.txt` and `/etc/udev/rules.d/90_mcloud.rules` files.
- Read carefully the `zebrunner-farm` output in syslog to identify the exact failure during containers creation.
- Analyze device container logs if the status is not `healthy`:

  ```bash
  docker ps -a | grep device
  # device connector container (adb for Android, usbmuxd and WebDriverAgent for iOS):
  docker logs -f device-<Name>-<udid>-connector
  # appium container:
  docker logs -f device-<Name>-<udid>-appium
  # STF provider container:
  docker logs -f device-<Name>-<udid>-stf
  # artifacts uploader container:
  docker logs -f device-<Name>-<udid>-uploader
  ```

- If you have any problems running ansible:
  - Make sure you have sudo access and try to run ansible with sudo permissions.
  - Try to rub ansible commands manually (`<devices_file>` name is `mac-devices` on macOS  or `devices` on Linux servers)

  > To download the required components and register the devices:

  ```bash
  ansible-playbook -vvv -i hosts <devices_file>.yml
  ```

  > To reregister the devices list only, you can use the following command:

  ```bash
  ansible-playbook -vvv -i hosts <devices_file>.yml --tag registerDevices
  ```

  > To run it non-interactively, keep the sudo password in an ansible-vault encrypted file instead of the command line (use `--vault-password-file` instead of `--ask-vault-pass` for automation):

  ```bash
  ansible-vault create become.yml    # with the line: ansible_become_password: PSWD
  ansible-playbook -vvv -i hosts --user=USERNAME --extra-vars @become.yml --ask-vault-pass <devices_file>.yml
  ```

## Development

The `tests` folder covers zebrunner.sh, the ansible roles and templates, zebrunner-farm, the macOS devices listener and the usbmuxd_watch binary. docker, sudo, launchctl, usbmuxd and other host tools are replaced by stubs, so the tests change nothing on the host.

- Run all linters and tests on this machine, then in the Linux docker image of `tests/Dockerfile` (macOS specific tests are skipped on Linux):

  ```bash
  make check
  ```

  > The linters of `tests/requirements-lint.txt` are installed into `.venv` automatically. On macOS install hadolint with `brew install hadolint`: the hadolint-py wheel for macOS is broken.

- Run a part of the checks with `make lint`, `make test` or `make docker`, `make` lists the targets.
- With `JUNIT_DIR` set, `tests/lint.sh` and every test write JUnit XML into it. CI publishes the results as annotations and a job summary, and keeps the XML files as artifacts.

The conventions of the style, the formatting and the tooling of this repository are in [CONVENTIONS.md](CONVENTIONS.md), the same in all the MCloud repositories.

## Support

- [Zebrunner PRO](https://zebrunner.com)
- [Zebrunner CE](https://zebrunner.github.io/community-edition)
- [Zebrunner Reporting](https://zebrunner.com/documentation)
- [Carina Guide](http://zebrunner.github.io/carina)
- [Demo Project](https://github.com/zebrunner/carina-demo)
- [Telegram Channel](https://t.me/zebrunner)

## License

[Apache License 2.0](LICENSE)
