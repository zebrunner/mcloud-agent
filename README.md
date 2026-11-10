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
| <b>Operating System</b> | Ubuntu 22.04+ (on 25.10+ see [sudo-rs](#troubleshooting))<br> macOS 13 (Ventura)+, Apple Silicon or Intel |
| <b>       CPU      </b> | 8+ Cores |
| <b>      Memory    </b> | 32 Gb RAM |
| <b>    Free space  </b> | SSD 128Gb+ of free space |

## Software prerequisites

- Install docker: [Docker Engine](https://docs.docker.com/engine/install/) on Linux, [Docker Desktop](https://docs.docker.com/desktop/setup/install/mac-install/) on macOS.
- Install [ansible](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html) 2.10+ (the playbooks use `ansible.builtin` module names, tested with ansible-core 2.21), e.g. `pip install ansible-core`.
- python3 and curl: `./zebrunner.sh join` and `doctor` need them. They read and write the settings with PyYAML of `python3` or, without it there, of the python of ansible (`ansible-playbook --version` shows it); `ZEBRUNNER_PYTHON` sets another one.
- macOS on Apple Silicon: install Rosetta 2 and let Docker Desktop use it: the image of appium is `linux/amd64` only and
  runs much slower under the QEMU emulation of Docker Desktop without it:

  ```bash
  softwareupdate --install-rosetta --agree-to-license
  ```

  then turn on *Use Rosetta for x86_64/amd64 emulation on Apple Silicon* in Docker Desktop (Settings, General) and
  restart it. `./zebrunner.sh setup` and `./zebrunner.sh status` report it.
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

- The setup ends with the numbered next steps: the invite of this host on the MCloud server, `./zebrunner.sh join`, the devices, `./zebrunner.sh doctor`, `./zebrunner.sh ansible` and `zebrunner-farm start`.

## Settings

The local settings of the host are in `config/`, out of git; `./zebrunner.sh setup` makes them from the examples (an existing file is kept, its copy goes to `<file>.bak`):

| File | What it is | Example |
| --- | --- | --- |
| `config/settings.yml` | the settings of the host, the same for Linux and macOS: the connection to MCloud of `./zebrunner.sh join`, S3, WebDriverAgent; mode 600, it has secrets | `config/settings.yml.original` |
| `config/devices.yml` | the list of the devices (`devices:`) | `config/devices.yml.original` (Linux), `config/mac-devices.yml.original` (macOS) |

The other files of the settings are in git, do not change them: `git pull` brings their new values. A line of `config/settings.yml` overrides any of them:

| File | What it is |
| --- | --- |
| `versions.yml` | the images of the devices and their versions |
| `roles/common/defaults/main.yml` | the values by default of both OS: the options of Appium (`APPIUM_RELAXED_SECURITY`, ...), `RESTARTS_LIMIT` |
| `roles/devices/defaults/main.yml`, `roles/mac-devices/defaults/main.yml` | the values by default of the OS: `STF_PROVIDER_NAME`; `USBMUXD_SOCKET_ADDRESS`, `ADB_SERVER_SOCKET_ADDRESS` of macOS |

The playbooks load them in this order: the values by default of the roles, `versions.yml`, `config/settings.yml`, `config/devices.yml`. The deploy renders the settings zebrunner-farm runs with into `/usr/local/etc/zebrunner-farm.env`: udev and launchd run it without the environment of the user, a change of `config/` needs `./zebrunner.sh ansible` (`./zebrunner.sh doctor` reports the settings that differ). `./zebrunner.sh backup` keeps the two files of `config/` in a private folder `backup/bak_<time>_<random>/config/`, `restore` puts them back; the code of the agent is not in a backup, it comes from git (`git pull`).

The earlier versions kept everything in `roles/devices/vars/main.yml` (Linux) or `roles/mac-devices/vars/main.yml` (macOS). Such a file overrides `config/`, so the deploy and `./zebrunner.sh doctor` refuse it: after `./zebrunner.sh setup` move its settings to `config/settings.yml` and its `devices:` to `config/devices.yml`, then remove it. The images and the options of Appium were in `defaults/main.yml`, now `versions.yml` and `roles/common/defaults/main.yml`: before `git pull` put the changed lines of `defaults/main.yml` into `config/settings.yml` and drop the local change (`git checkout defaults/main.yml`).

## Node enrollment

Every device host joins [MCloud](https://github.com/zebrunner/mcloud#nodes) with its own token: the administrator of MCloud invites it, the host enrolls itself, no secret is copied by hand.

1. On the MCloud server: `./zebrunner.sh node-invite <label> <address>`. The label is the name of the host (`a-z`, `0-9`, `-`), the address is the one the MCloud server connects to: the hub registers the Appium nodes by it, stf-proxy takes the screens from it (in the network of the MCloud server the address there, see [Device hosts in a private network](#device-hosts-in-a-private-network); on the MCloud server itself its LAN address, see [Devices on the MCloud server](#devices-on-the-mcloud-server)). It prints a join string, valid once and for a limited time; a new invite of the label replaces it.
2. On this host: `./zebrunner.sh join` asks for the join string (hidden; or on stdin: never in the command line, where it stays in the shell history) and enrolls the host:
   - it makes the CURVE key of the host if there is none and sends its public key, never the secret one;
   - it talks to MCloud over HTTPS and trusts only the server whose TLS key is the pinned one of the join string (a self-signed certificate is fine, another key stops the enrollment);
   - it writes the connection to MCloud into `config/settings.yml` (mode 600, the previous settings are kept in `settings.yml.bak-join-<time>`).
3. `./zebrunner.sh doctor`, `./zebrunner.sh ansible` and `zebrunner-farm start` (`restart` for the existing containers).

The settings of the connection, written by `join` (do not change them by hand, a new join string replaces them):

| Setting | Value |
| --- | --- |
| `MCLOUD_URL`, `MCLOUD_TLS_PIN` | the API of MCloud on the address of the join string and the pin of its TLS key: `./zebrunner.sh doctor` checks the enrollment with them |
| `MCLOUD_NODE_TOKEN` | the token of this host: appium registers in mcloud-grid with it (`NODE_REGISTRATION_TOKEN` of appium), STF of the devices authenticates to the storage and proves its devices with it (`STF_NODE_TOKEN` of mcloud-device) |
| `STF_PROVIDER_HOST` | the address of the invite |
| `PUBLIC_IP`, `PUBLIC_IP_PORT`, `PUBLIC_IP_PROTOCOL` | the public URL of MCloud: the devices upload the screenshots and download the apps there |
| `STF_PROVIDER_CONNECT_*`, `SELENIUM_HUB_HOST`, `SELENIUM_HUB_PORT` | the triproxies of STF and mcloud-grid on the address of the join string |
| `STF_ZMQ_CURVE_SERVER_PUBLIC_KEY`, `STF_ZMQ_CURVE_SECRET_KEY` | the CURVE keys of ZeroMQ: the one of the server and the one of this host, see [ZeroMQ security](#zeromq-security) |

`REMOTE_CONNECT_HOST` is set by hand when needed, see [Device hosts in a private network](#device-hosts-in-a-private-network).

Security:

- the token is of this host only: MCloud keeps its hash, binds it to the address of the host and to its devices, and revokes it alone (`./zebrunner.sh nodes revoke <label>` of mcloud);
- `config/settings.yml` and the deployed settings of `zebrunner-farm` (`/usr/local/etc/zebrunner-farm.env`) have the secrets of the host: `config/settings.yml` is mode 600, the settings of `zebrunner-farm` are readable by root and the user of the deploy only (Linux: mode 640, the group of the user; macOS: mode 600, the user); the script `zebrunner-farm` has no secret; the users of the `docker` group can read the variables of the containers anyway, they are root on the host;
- a new join string (`node-invite` of the same label) replaces the token and the key of the host: run `./zebrunner.sh join` again to rotate them;
- `./zebrunner.sh doctor` asks MCloud about this host (enrolled, active, its address, the devices STF knows and binds to it) and reports the settings readable by other users.

## Run ansible playbook

- The images of the devices are pinned in `versions.yml`: `DEVICE_VERSION` (mcloud-device), `APPIUM_VERSION`,
  `IOS_CONNECTOR_VERSION`, `ANDROID_CONNECTOR_VERSION` and `UPLOADER_VERSION`. mcloud-device must be the one of the STF
  of [mcloud](https://github.com/zebrunner/mcloud) (`TAG_STF` of its `.env`). Another version is a line of
  `config/settings.yml` (see [Settings](#settings)).
- [Optional] To compare images in the tests (the Appium images plugin) append the `-img` postfix to `APPIUM_VERSION` in `config/settings.yml`,
  the `appium-image` stage of [appium](https://github.com/zebrunner/appium#build):

  ```yaml
  APPIUM_VERSION: 3.0-img
  ```

  > The published appium images: <https://gallery.ecr.aws/zebrunner/appium>

### Linux OS

- update `config/settings.yml` and `config/devices.yml` files according to the obligatory/optional comments inside (see [Settings](#settings)).
  > Register all whitelisted Android and iOS devices with their udids!
  > The deploy validates the devices: obligatory settings, unique ids and names, and host ports (`appium_port`, `min_port`-`max_port`, `connect_port`) not shared by devices. `adb_port` is not used on Linux; `connect_port` (optional, Android) is the remote debug port of STF.
- Run ansible-playbook script to download the required components (the connector of the platforms of the registered devices only) and set up udev rules:

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

- Running containers of the devices keep the settings and the images they were created with: `./zebrunner.sh ansible` lists them and offers to remove them first (`zebrunner-farm down`, Enter is yes), otherwise run `zebrunner-farm restart` after the deploy.
- Run `zebrunner-farm start` to create the containers of the devices connected before the deploy and of the wireless,
  emulator and proxy devices: udev starts the containers of a USB device on its next connection only.
- Devices management script is deployed to /usr/local/bin/zebrunner-farm (the same script on Linux and macOS), its settings to /usr/local/etc/zebrunner-farm.env (see [Settings](#settings)).
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

- update `config/settings.yml` and `config/devices.yml` files according to the obligatory/optional comments inside (see [Settings](#settings)).
  > Register all whitelisted Android and iOS devices (phones, tablets, TVs or simulators) with their udids and connections!
  > The deploy validates the devices: obligatory settings, unique ids and names, the connections, host ports (`appium_port`, `min_port`-`max_port`, `connect_port`, `wda_port` and `mjpeg_port` of the iOS simulators, `adb_port` of the USB Android devices) not shared by devices.
- Run ansible-playbook script to download the required components (the connector of the platforms of the registered devices only) and set up launchd agents:

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

- Devices management script is deployed to /usr/local/bin/zebrunner-farm (the same script on Linux and macOS), its settings to /usr/local/etc/zebrunner-farm.env (see [Settings](#settings)).
- The containers run on the platform of the Mac, arm64 on Apple Silicon (the STF provider of an iOS simulator hangs
  under emulation, the other ones are slower), but appium: its image is `linux/amd64` only (see
  [appium](https://github.com/zebrunner/appium#limitations)), emulated by Docker Desktop with Rosetta 2 on Apple Silicon.
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
- `status` - shows the state of the agent components: tools, Rosetta 2 of an Apple Silicon Mac, deployed files, launch agents.
- `backup` and `restore` - save the settings of `config/` into the `backup` folder and restore them from it (see [Settings](#settings)); a backup of an earlier version (`vars/main.yml`) is moved by hand.
- `shutdown` - removes the devices containers, the launch agents or udev rules, the deployed files, the settings and the environment variable (asks for confirmation).
- `version` - shows the versions of the agent components.
- `doctor` - checks the host, the settings, the deployment, the network to the MCloud server and the devices, and tells what to fix, see [Doctor](#doctor).
- `join` - enrolls this host in MCloud with the join string of `./zebrunner.sh node-invite` of mcloud, see [Node enrollment](#node-enrollment).

### ZeroMQ security

STF of MCloud accepts on its ZeroMQ ports only the enrolled device hosts: the CURVE key of every host is in the registry of MCloud. `./zebrunner.sh join` makes the key of this host (`STF_ZMQ_CURVE_SECRET_KEY`, kept when it is set), sends its public key and writes the public key of the server (`STF_ZMQ_CURVE_SERVER_PUBLIC_KEY`); a revocation of the host on the MCloud server disconnects it. `patch/curve_keygen.py` makes the keys with Python only (X25519 of RFC 7748), the same as `stf curve-keygen`.

### Doctor

`./zebrunner.sh doctor` checks the agent and tells what to fix, it changes nothing and prints no secret:

- the host: `ZEBRUNNER_MCLOUD_AGENT_DIR`, docker, ansible, python3, lsusb (Linux), Rosetta 2 (Apple Silicon);
- the YAML of `config/settings.yml` and `config/devices.yml`: doctor reads the settings as the playbooks load them (the values by default of the roles, `versions.yml`, `config/settings.yml`), a file that is not valid YAML is a problem;
- the settings of `config/settings.yml`: the ones of `./zebrunner.sh join`, the formats of the token and of the CURVE keys, the file readable by other users, a `roles/.../vars/main.yml` of an earlier version; the devices of `config/devices.yml`;
- the enrollment: it asks MCloud about this host (`GET /api/v1/nodes/self` of `MCLOUD_URL` with the token, over HTTPS to the pinned TLS key): enrolled and active (or unknown, revoked), its address in MCloud is `STF_PROVIDER_HOST`, the devices STF knows of it, which of them are bound to it and connected;
- the deployment: the settings of `zebrunner-farm` (`/usr/local/etc/zebrunner-farm.env`) are the current ones, also the versions of the images (otherwise `./zebrunner.sh ansible`) and readable by this user only, the containers created with the current `STF_PROVIDER_HOST` (otherwise `zebrunner-farm restart`);
- the network: the name resolution and the ports of `PUBLIC_IP`, mcloud-grid and the ZeroMQ triproxies; `STF_PROVIDER_HOST` is an address of this host, or a public address of a NAT while the MCloud server is in the network of this host (see [Device hosts in a private network](#device-hosts-in-a-private-network)); MCloud on this machine and the devices using its ports (see [Devices on the MCloud server](#devices-on-the-mcloud-server));
- the remote debug: with `REMOTE_CONNECT_HOST` the adb relay of mcloud accepts the remote debug ports of the Android devices (printed);
- the devices: their containers, the refused grid registrations of Appium and the refused CURVE key in the logs of the last 30 minutes.

The MCloud server checks a host too: `./zebrunner.sh nodes check <label>` of [mcloud](https://github.com/zebrunner/mcloud#nodes) shows its record, its devices and whether the server reaches their screens.

It exits with `1` when a check fails.

### Device hosts in a private network

Many device hosts without public addresses can work with one MCloud server of their network: the users reach the MCloud server only. The screens go from the browser to stf-proxy of mcloud (`/d/<STF_PROVIDER_HOST>/...`) and from it to the device host, the tests go to mcloud-grid and from it to the Appium node of the device host (`http://<STF_PROVIDER_HOST>:<appium_port>`); ZeroMQ, the storage and S3 are connections of the device host to the server.

- Every device host is invited with its address in the network (`./zebrunner.sh node-invite <label> <address>`), which `join` writes as its `STF_PROVIDER_HOST`.
- `PUBLIC_IP` stays the name the users open MCloud with: the device host resolves it to the address of the server in the network (e.g. a line in `/etc/hosts`, the containers resolve the names through the resolver of the host); `STF_PROVIDER_CONNECT_*`, `SELENIUM_HUB_HOST` and `MCLOUD_URL` are on the address of the join string.
- A public address of the router as the address of the invite fails inside the network when the router has no NAT hairpin: mcloud-grid refuses the nodes (Appium logs the registration `500` with `Node http://... is not reachable from the hub`) and the screens stay gray. `./zebrunner.sh doctor` finds it and prints the address to invite the host with.
- The remote debug of STF (`adb connect <host>:<port>`) of an Android device uses its remote debug port: `connect_port` of the device, the second port of `min_port`-`max_port` without it (the first one is the screen, which is never relayed). It goes through the adb relay of mcloud: set `REMOTE_CONNECT_HOST` to the public name of MCloud and turn on `ADB_RELAY=true` in `.env` of mcloud, the relay takes the remote debug ports of the devices of the enrolled hosts from STF; `ADB_RELAY_PORTS` of mcloud limits them to the range opened in its firewall, so keep the `connect_port` of all the device hosts in one range, unique among the hosts (see [mcloud](https://github.com/zebrunner/mcloud#readme)). Without the relay only the users of the network reach `adb connect <STF_PROVIDER_HOST>:<port>`.
- `./zebrunner.sh doctor` checks the relay on the remote debug port of the first deployed Android device and prints the remote debug ports of this host. The remote debug is of the Android devices only.

### Devices on the MCloud server

The devices can be on the MCloud server itself (mcloud and mcloud-agent on one machine):

- `AGENTS_ADDRESS` of `.env` of mcloud is the LAN address of the machine, so is the address of the invite (`./zebrunner.sh node-invite <label> <LAN address>`): not `127.0.0.1` or `localhost`, which the containers of mcloud cannot reach the devices with (MCloud refuses them);
- the devices share the `infra` network with mcloud and reach the published ports of MCloud on that address;
- the ports of the devices (`appium_port`, `min_port`-`max_port`, `connect_port`) are not the ports of MCloud: its HTTPS port (`STF_PORT`), 4446 (mcloud-grid), 7160, 7250, 7260, 7270 (the triproxies of STF) and the remote debug ports of the adb relay; `./zebrunner.sh doctor` reports the collisions.

### Grid registration

The Appium node of a device registers in mcloud-grid with the token of this host (`MCLOUD_NODE_TOKEN`, passed to appium as `NODE_REGISTRATION_TOKEN`): the hub accepts it only when STF knows the token of an active host whose address is the host of the node url (`STF_PROVIDER_HOST`), checks it again every minute and sends it back to this node only with every request, see [mcloud-grid](https://github.com/zebrunner/mcloud-grid#node-registration). A revoked host is unregistered.

### Appium security

The Appium port of a device (`appium_port`) is published on the host for mcloud-grid. Appium of the device answers only the requests of the grid, which carry the token of this host, and the ones of its own container: the others get `401` (also Appium Inspector and the WebSockets of the sessions, e.g. the logcat broadcast; use the grid, `/mcloud/wd/hub` of mcloud).

`APPIUM_RELAXED_SECURITY` of `roles/common/defaults/main.yml` is `true`: every session, also through the grid, gets the insecure features of Appium: `mobile: shell` (adb shell of the device), the Appium log of the earlier sessions of the device (`get_server_logs`), the emulator console, the screen streaming, the download of chromedriver. Set it to `false` in `config/settings.yml` when the tests do not need them.

### Devices management

`zebrunner-farm <command> [devices...] [-x|--exclude <devices>]... [-q|--quiet] [--batch|--rolling]` manages the containers of the devices: `status`, `start` (creates the missing containers, starts the stopped ones, keeps the running ones), `stop`, `restart` (removes and creates them again) and `down` (removes them).

- `restart` of several devices has two strategies: `--batch` (the default, `--strategy batch`) removes the containers of all the devices one by one, then creates and starts them; `--rolling` (`--strategy rolling`) removes and creates the containers device by device, the other devices keep working meanwhile. The question of a terminal shows the strategy, `s` switches it.

- The devices are udids or names, groups (`ios`, `android`, `usb`, `wireless`, `android-sim`, `ios-sim`, `proxy`) or patterns of the udids, names and locations in quotes (`'Samsung_*'`), several ones separated by spaces or commas; all the devices without them.
- `-x` (`-e`, `--exclude`, also `-x=<devices>`) skips devices, groups or patterns, e.g. `zebrunner-farm restart android -x Pixel_8_Pro -x 'Samsung_Galaxy_S2?'`.
- In a terminal `start`, `stop`, `restart` and `down` of a group show the numbered devices with the state of their containers and ask: Enter or `y` runs the command, `n` cancels, `f <devices>` keeps only these devices of the list, `x <devices>` excludes them; `<devices>` are the numbers of the list, udids, names, groups or patterns. `-q` (`--quiet`) runs at once; a single device named exactly, udev, launchd and scripts without a terminal are not asked.
- Every device prints one line per container: `running` (kept), `started`, `created <id>` or the error of docker; the containers after a failed one are not created.

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
9. Share built ipa via WDA_FILE variable in config/settings.yml file.
   > to override WDA_FILE artifacts per each device use `wda_file` and `wda_bundleid` iOS device properties and re-execute ansible playbook.
10. The device connector installs WebDriverAgent from the ipa on Linux and on macOS (over usbmuxd of the host), a WebDriverAgent started on macOS by the host is used as is.

### SmartTestFarm

- Open in your browser `http://<PUBLIC_IP>/stf`, authenticate yourself based on preconfigured auth system.
- The connected device should be available in STF.
- Disconnect the device from the server. Device containers will be removed asap, then, in 15-30 sec, the device should change the state in STF to disconnected as well.
- Use different commands from `zebrunner-farm start/stop/restart/down/status` to manage all devices, a device by udid or name, or all devices of a platform (ios/android).
  > Run `zebrunner-farm` to see available options.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `./zebrunner.sh ansible` fails on `Pull Zebrunner images` and `Check that images failed to pull exist locally` with `denied: Your authorization token has expired` or `403 Forbidden` | an expired login to public.ecr.aws in `~/.docker/config.json` of the user: the images are public, `docker logout public.ecr.aws` (or log in again) |
| the pull fails with `manifest unknown` | the tag of `versions.yml` (or of `config/settings.yml`) is not published, see the images of the current [mcloud](https://github.com/zebrunner/mcloud) |
| Linux: the deploy passed, the devices plugged in before it have no containers | udev starts them on the next connection only: `zebrunner-farm start` |
| `./zebrunner.sh join` stops with `the TLS key of the server is not the pinned one` | the join string is of another MCloud (or the address of the join string leads elsewhere), or a man in the middle; a new TLS key of MCloud needs a new join string |
| `./zebrunner.sh join` stops with `MCloud refused the enrollment (HTTP 403)` | the invite is used, expired, replaced by a newer one of the label, or of another label: a new `./zebrunner.sh node-invite` on the MCloud server |
| the containers are healthy, the devices are not in STF | `./zebrunner.sh doctor`: MCloud does not know or revoked this host (a new invite and `./zebrunner.sh join`), its address in MCloud is not `STF_PROVIDER_HOST`, the devices are not bound to it (the containers created before `join`: `./zebrunner.sh ansible`, `zebrunner-farm restart`); the STF triproxies log `Refused the ZeroMQ client ... with the unknown key` for a key MCloud does not know, see [ZeroMQ security](#zeromq-security) |
| the devices are in STF, not in the grid; Appium logs `An attempt to register with the grid was unsuccessful` | the reason is in the log of Appium (`device-<name>-<udid>-appium`) or of `mcloud-grid`: `is not reachable from the hub` - `STF_PROVIDER_HOST` and `appium_port` are not reachable from the MCloud server (in its network the address of this host there, see [Device hosts in a private network](#device-hosts-in-a-private-network)); an unknown or revoked node token, or a node url whose host is not the address of the invite - `./zebrunner.sh doctor`, see [Grid registration](#grid-registration) |
| the screenshots or the app installs of the devices fail | MCloud refuses the token of this host (`./zebrunner.sh doctor`), or `PUBLIC_IP` is not reachable from this host (e.g. the public address of a server of the same network behind a NAT without hairpin: resolve it to its address in the network) |
| the uploader container exits with `Required S3 arguments are missed! Integration with S3 will be disabled.` | no `S3_*` settings: the videos and logs stay on the host, set them to upload the artifacts |
| macOS: an iOS simulator is not in STF, the log of its `-stf` container stops after `connecting to WdaMjpeg` | the amd64 mcloud-device under emulation: the arm64 one of a multi-platform mcloud-device image is needed on Apple Silicon (`docker image inspect <image> --format '{{.Architecture}}'`) |

Run `./zebrunner.sh doctor` first, see [Doctor](#doctor). Follow the below algorithm to identify any configuration issues with MCloud agent:

- macOS: the devices listener logs into `logs/listener.log` and `logs/listener.err.log`, the usbmuxd sharing (socat) into `logs/usbmuxd-socat.log` and `logs/usbmuxd-socat.err.log` of the MCloud agent directory. `listener.log` is rotated by newsyslog (10 MB, 7 bzip2 archives, `/etc/newsyslog.d/zebrunner-mcloud.conf`). Loaded agents are shown by `launchctl list | grep zebrunner`.
- Linux: enable the debug log level for udev rules: `sudo udevadm control --log-priority=debug`.
- Linux: the connections and disconnections of a USB device and the output of `zebrunner-farm` for them are in the journal of its units:

  ```bash
  journalctl -f -u 'mcloud-device-*@<id>'
  ```

- If there are no updates during connection/disconnection, please, verify the correctness of:
  - device udid values,
  - presence of `/usr/local/bin/zebrunner-farm` and of its settings `/usr/local/etc/zebrunner-farm.env`,
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
- `tests/golden/farm-linux.txt` and `tests/golden/farm-macos.txt` are the `docker` and `launchctl` calls and the output of `zebrunner-farm` for every kind of device (`tests/farm_golden_test.sh`): a change of the containers fails the test. After an intended change regenerate them and review their diff in the pull request:

  ```bash
  UPDATE_GOLDEN=1 tests/farm_golden_test.sh
  ```

- The roles: `devices` (Linux) and `mac-devices` (macOS) deploy the agent of the OS; `common`, their dependency (`meta/main.yml`), has the values by default and the checks of the settings and the devices shared by both (`roles/common/tasks/checks.yml`, imported after the check of the OS: a check of one OS only stays in its role), and `zebrunner-farm` (`roles/common/tasks/farm.yml`): one static script of both OS (`roles/common/files/zebrunner-farm`, the branches of `FARM_OS`) with its settings rendered into an env file (`roles/common/templates/zebrunner-farm.env`); the tests run it with `ZEBRUNNER_FARM_ENV`; `download` pulls the images.
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
