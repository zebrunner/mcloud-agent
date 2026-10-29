# Zebrunner Device Farm (Android and iOS agent)

The agent runs the containers of every device of a Linux or macOS server: the connector (the only point of contact with
the device), STF, Appium and the artifacts uploader. The connector takes the device whatever its connection is, the STF and
Appium containers always take adb, usbmuxd and WebDriverAgent from it.

| Device | Connection | Linux | macOS |
| --- | --- | --- | --- |
| Android phone, tablet, TV | `usb` | adb server of the connector (USB passed in) | adb server of the host (a launch agent), the connector forwards the device to its own adb server |
| Android | `wireless` | adb connect of the connector | adb connect of the connector |
| Android emulator (AVD, Genymotion, a container Android) started outside the farm | `android-sim` | adb connect of the connector to the `address` of the emulator | the same, an AVD of the Mac is `host.docker.internal:5555` |
| iPhone, iPad, Apple TV HD | `usb` | usbmuxd of the connector | usbmuxd of the host, the connector installs and starts WebDriverAgent over it |
| iPhone, iPad, Apple TV over Wi-Fi | `wireless` | netmuxd of the connector at `address` (paired over USB first) | usbmuxd of the host (paired with the Mac) |
| iOS, iPadOS, tvOS simulator | `ios-sim` | - | the connector runs `xcrun simctl` of the host over ssh |
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
| <b>Operating System</b> | Ubuntu 22.04+ (on 25.10+ see [sudo-rs](#troubleshooting))<br>Linux CentOS 7+<br>Amazon Linux2<br> macOS 13 (Ventura)+, Apple Silicon or Intel |
| <b>       CPU      </b> | 8+ Cores |
| <b>      Memory    </b> | 32 Gb RAM |
| <b>    Free space  </b> | SSD 128Gb+ of free space |

## Software prerequisites

- Install docker: [Docker Engine](https://docs.docker.com/engine/install/) on Linux ([Amazon Linux 2](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/docker-basics.html)), [Docker Desktop](https://docs.docker.com/desktop/setup/install/mac-install/) on macOS.
- Install [ansible](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html) 2.10+ (the playbooks use `ansible.builtin` module names, tested with ansible-core 2.21), e.g. `pip install ansible-core`.
- macOS: install socat utility to share usbmuxd websocket into the device containers
  > valid path to socat binary should be `/usr/local/bin/socat`
  > on Apple Silicon Homebrew installs it to `/opt/homebrew/bin/socat`, link it: `sudo ln -s /opt/homebrew/bin/socat /usr/local/bin/socat`
- The server of [mcloud](https://github.com/zebrunner/mcloud) is set up and started: the devices connect to it.

## Clone and setup

- Clone mcloud-agent repository and execute setup procedure

  ```bash
  git clone https://github.com/zebrunner/mcloud-agent.git
  cd mcloud-agent
  ./zebrunner.sh setup
  ```

## Connect to MCloud

Set the settings of the MCloud server in `roles/devices/vars/main.yml` (Linux) or `roles/mac-devices/vars/main.yml`
(macOS), which `./zebrunner.sh setup` made; the secrets in quotes:

| Setting | Value |
| --- | --- |
| `PUBLIC_IP`, `PUBLIC_IP_PORT`, `PUBLIC_IP_PROTOCOL` | the host, port and protocol of the setup of mcloud (`STF_URL` of its `.env`), reachable from this host: the devices upload the screenshots and download the apps there |
| `STF_PROVIDER_HOST` | the address of this host the users and the MCloud server reach: add it to `AGENT_HOSTS` of `.env` of mcloud and run `./zebrunner.sh restart` there, stf-proxy serves the screens of its devices then |
| `STF_STORAGE_TOKEN`, `STF_ZMQ_CURVE_SERVER_PUBLIC_KEY`, `NODE_REGISTRATION_TOKEN` | the same variables of `variables.env` of mcloud, its setup prints them |
| `STF_ZMQ_CURVE_SECRET_KEY` | `./zebrunner.sh curve-key` makes it and prints its public key: add the public key to `STF_ZMQ_CURVE_CLIENT_KEYS` of `variables.env` of mcloud and run `./zebrunner.sh restart` there, see [ZeroMQ security](#zeromq-security) |
| `STF_PROVIDER_CONNECT_*`, `SELENIUM_HUB_HOST`, `SELENIUM_HUB_PORT` | the defaults are the containers of mcloud in the `infra` network of the same host; for an MCloud server on another host: `tcp://<server>:7250`, `tcp://<server>:7270`, `tcp://<server>:7160`, `tcp://<server>:7260`, `<server>` and `4446` (see [Firewall of mcloud](https://github.com/zebrunner/mcloud#firewall)) |

## Run ansible playbook

- The images of the devices are pinned in `defaults/main.yml`: `DEVICE_VERSION` (mcloud-device), `APPIUM_VERSION`,
  `IOS_CONNECTOR_VERSION`, `ANDROID_CONNECTOR_VERSION` and `UPLOADER_VERSION`. mcloud-device must be the one of the STF
  of [mcloud](https://github.com/zebrunner/mcloud) (`TAG_STF` of its `.env`).
- [Optional] To compare images in the tests (the Appium images plugin) append the `-img` postfix to `APPIUM_VERSION`,
  the `appium-image` stage of [appium](https://github.com/zebrunner/appium#build):

  ```yaml
  APPIUM_VERSION: 3.0-img
  ```

  > The published appium images: <https://gallery.ecr.aws/zebrunner/appium>

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

- Run `zebrunner-farm start` to create the containers of the devices connected before the deploy and of the wireless,
  emulator and proxy devices: udev starts the containers of a USB device on its next connection only.
- Devices management script is deployed to /usr/local/bin/zebrunner-farm.
- Udev rules with whitelisted devices are in /etc/udev/rules.d/90_mcloud.rules: a connection of a USB device starts the systemd unit `mcloud-device-restart@<id>`, a disconnection `mcloud-device-down@<id>` (`/etc/systemd/system`), which run `zebrunner-farm restart` or `down` for it. udev only queues the job: its programs are killed after the event (180 s), the containers may need longer (the images are pulled). A disconnection cancels an unfinished restart and the other way round.
- The commands of one device (`zebrunner-farm start`, `stop`, `restart`, `down <device>`, the units of udev) run one at a time (`flock`, `/run/lock/mcloud-device-<id>.lock`): one waits for up to 30 minutes for another.
- Whitelisted devices properties are in /usr/local/bin/mcloud-devices.txt.
- Usbmuxd service is stopped and masked (disabled).
- Wireless, emulator and proxy devices have no udev rules: `zebrunner-farm start` creates their containers.
- Android emulators (`android-sim`) are started outside the farm (e.g. an AVD, Genymotion, a container Android): set `address` to their adb address reachable from the docker network; appium gets `DEVICE_CONNECTION=android-sim` (a `default` device is a phone).
- [Optional] Register`@reboot /usr/local/bin/zebrunner-farm restart` via crontab to forcibly restart containers on reboot
- [Optional] Increased `fs.inotify.max_user_instances` to workaround [#328](https://github.com/zebrunner/mcloud-agent/issues/328)
  > `sudo sysctl fs.inotify.max_user_instances=2048`

### Mac OS

- update `roles/mac-devices/vars/main.yml` file according to the obligatory/optional comments inside.
  > Register all whitelisted Android and iOS devices (phones, tablets, TVs or simulators) with their udids and connections!
  > The deploy validates the devices: obligatory settings, unique ids and names, the connections, host ports (`appium_port`, `min_port`-`max_port`, `wda_port` and `mjpeg_port` of the iOS simulators, `adb_port` of the USB Android devices) not shared by devices.
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
- The mcloud-device containers run on the platform of the Mac, arm64 on Apple Silicon (the STF provider of an iOS
  simulator hangs under emulation); the connectors, appium and the uploader are `linux/amd64` images, emulated by Docker
  Desktop on Apple Silicon.
- Whitelisted devices properties are in /usr/local/bin/mcloud-devices.txt.
- Deployed and loaded $HOME/Library/LaunchAgents/ZebrunnerUsbmuxd.plist to share usbmuxd into the device containers
- USB Android devices: deployed and loaded $HOME/Library/LaunchAgents/ZebrunnerAdb.plist, the adb server of the host (`brew install android-platform-tools`); the connectors take the devices from it, the containers of a USB Android device are created by `zebrunner-farm start` (the devices listener handles iOS only).
- iOS simulators (`ios-sim`): the ssh key of the agent is generated into `ssh/id_ed25519` of the agent folder and authorized in `~/.ssh/authorized_keys` (`restrict`), turn on Remote Login (System Settings, General, Sharing) for the user. Set the simulator build of WebDriverAgent (`WDA_SIMULATOR_FILE` or `wda_file` of the device), e.g. `WebDriverAgentRunner-Build-Sim-arm64.zip` of [appium/WebDriverAgent](https://github.com/appium/WebDriverAgent/releases).
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
- `curve-key` - makes the CURVE key of this host for the ZeroMQ security of STF (`STF_ZMQ_CURVE_SECRET_KEY` of `roles/.../vars/main.yml`, kept when it is set) and prints its public key, see [ZeroMQ security](#zeromq-security).

### ZeroMQ security

The STF server of [mcloud](https://github.com/zebrunner/mcloud#authentication-of-the-device-hosts) accepts on its ZeroMQ ports only the device hosts with a known CURVE key (a new deployment, or one that turned the authentication on). Its device containers need the mcloud-device image of the current STF; for every device host:

1. `./zebrunner.sh curve-key` makes the key of the host and prints its public key.
2. Add the public key to `STF_ZMQ_CURVE_CLIENT_KEYS` of `variables.env` of the STF server (separated by commas) and restart the server.
3. Set `STF_ZMQ_CURVE_SERVER_PUBLIC_KEY` of `roles/.../vars/main.yml` to the one of `variables.env` of the server, in quotes, and run `./zebrunner.sh ansible`: the device containers connect over CURVE and without RethinkDB (`STF_RETHINKDB` is not passed then), the prechecks of the playbook validate the keys; `zebrunner-farm restart` recreates the existing containers with the keys.

The removal of the public key of a host from `STF_ZMQ_CURVE_CLIENT_KEYS` disconnects it. `patch/curve_keygen.py` makes the keys with Python only (X25519 of RFC 7748), the same as `stf curve-keygen`.

### Grid registration

The Appium node of a device registers in mcloud-grid with `NODE_REGISTRATION_TOKEN` of `roles/.../vars/main.yml`: set it to `NODE_REGISTRATION_TOKEN` of `variables.env` of [mcloud](https://github.com/zebrunner/mcloud#authentication-of-the-device-hosts), in quotes, and run `./zebrunner.sh ansible`; the containers created after it pass the token, `zebrunner-farm restart` recreates the existing ones. A hub with a token (a new deployment of mcloud, or one that turned the authentication on) registers no node without it, see [mcloud-grid](https://github.com/zebrunner/mcloud-grid#node-registration). It needs the appium image that sends the token.

### Appium security

The Appium port of a device (`appium_port`) is published on the host for mcloud-grid. With `NODE_REGISTRATION_TOKEN` Appium of the device answers only the requests of the grid, which carry the token, and the ones of its own container: the others get `401` (also Appium Inspector and the WebSockets of the sessions, e.g. the logcat broadcast; use the grid, `/mcloud/wd/hub` of mcloud). Without the token anyone who reaches the host uses the device bypassing the grid and its reservation in STF. It needs the appium image that checks the token.

`APPIUM_RELAXED_SECURITY` of `defaults/main.yml` is `true`: every session, also through the grid, gets the insecure features of Appium: `mobile: shell` (adb shell of the device), the Appium log of the earlier sessions of the device (`get_server_logs`), the emulator console, the screen streaming, the download of chromedriver. Set it to `false` when the tests do not need them.

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
- Linux: the connections and disconnections of a USB device and the output of `zebrunner-farm` for them are in the journal of its units:

  ```bash
  journalctl -f -u 'mcloud-device-*@<id>'
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
  - Try to run ansible commands manually (`<devices_file>` name is `mac-devices` on macOS  or `devices` on Linux servers)

  > To download the required components and register the devices:

  ```bash
  ansible-playbook -vvv --ask-become-pass -i hosts <devices_file>.yml
  ```

  > To reregister the devices list only, you can use the following command:

  ```bash
  ansible-playbook -vvv --ask-become-pass -i hosts <devices_file>.yml --tag registerDevices
  ```

  Ubuntu 25.10+ has sudo-rs as `sudo`: ansible does not recognize its password prompt and stops with "Timed out
  waiting for become success or become password prompt". `./zebrunner.sh ansible` uses `sudo.ws` (the original sudo,
  `sudo apt install sudo`) then, add `--extra-vars ansible_become_exe=sudo.ws` to the commands above.

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
- The `usbmuxd_watch` binary of the `mac-devices` role is built from `roles/mac-devices/files/usbmuxd_watch.c` and the pinned release tarballs (sha256) of libplist, libimobiledevice-glue and libusbmuxd. After a change of the source or of a library version, rebuild it on macOS with the Xcode command line tools and commit it; the same Xcode builds the same binary byte for byte. CI builds it the same way and runs `tests/usbmuxd_watch_test.sh` on the result:

  ```bash
  scripts/build_usbmuxd_watch.sh
  ```

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
