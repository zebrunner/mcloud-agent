# Zebrunner Device Farm (Android and iOS agent)

The agent runs the containers of every device of a Linux or macOS server: the connector (the only point of contact with
the device), STF, Appium and the artifacts uploader (with S3, see [Recordings](#recordings)). The connector takes the device whatever its connection is, the STF and
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
- Linux: the user of the agent runs docker without sudo (the deploy pulls the images, `zebrunner.sh` and `zebrunner-farm` manage the containers as this user): `sudo usermod -aG docker $USER`, then log in again.
- Install [ansible](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html) 2.10+ (the playbooks use `ansible.builtin` module names, tested with ansible-core 2.22, the version of CI in `tests/requirements-lint.txt`), e.g. `pip install ansible-core`.
- python3 and curl: `./zebrunner.sh join` and `doctor` need them. They read and write the settings with PyYAML of `python3` or, without it there, of the python of ansible (`ansible-playbook --version` shows it); `ZEBRUNNER_PYTHON` sets another one.
- macOS on Apple Silicon: install Rosetta 2 and let Docker Desktop use it: the image of appium is `linux/amd64` only and runs much slower under the QEMU emulation of Docker Desktop without it:

  ```bash
  softwareupdate --install-rosetta --agree-to-license
  ```

  then turn on *Use Rosetta for x86_64/amd64 emulation on Apple Silicon* in Docker Desktop (Settings, General) and restart it. `./zebrunner.sh setup` and `./zebrunner.sh status` report it.
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
| `roles/common/defaults/main.yml` | the values by default of both OS: the options of Appium (`APPIUM_RELAXED_SECURITY`, ...), `RESTARTS_LIMIT`, `STF_DOCKER_NETWORK` (`infra`: the docker network of the containers of the devices, the deploy and `zebrunner-farm` create it), the empty optional settings (`STF_API_URL`, `S3_*`, `WDA_FILE`, `WDA_BUNDLEID`, the supervision identity of the [MDM](#mdm) `MDM_SUPERVISION_P12*`), the [WireGuard tunnel](#wireguard-tunnel) off (`WG_ENABLED: false`, the empty `WG_*`, `WG_PERSISTENT_KEEPALIVE: 25`): a line of them removed from `config/settings.yml` is the value by default, the [Developer Disk Images](#developer-disk-images) (`DDI_*`) |
| `roles/devices/defaults/main.yml`, `roles/mac-devices/defaults/main.yml` | the values by default of the OS: `STF_PROVIDER_NAME`; `USBMUXD_SOCKET_ADDRESS`, `ADB_SERVER_SOCKET_ADDRESS` of macOS |

The playbooks load them in this order: the values by default of the roles, `versions.yml`, `config/settings.yml`, `config/devices.yml`. The deploy renders the settings zebrunner-farm runs with into `/usr/local/etc/zebrunner-farm.env`: udev and launchd run it without the environment of the user, a change of `config/` needs `./zebrunner.sh ansible` (`./zebrunner.sh doctor` reports the settings that differ). `./zebrunner.sh backup` keeps the two files of `config/` in a private folder `backup/bak_<time>_<random>/config/`, `restore` puts them back; the code of the agent is not in a backup, it comes from git (`git pull`).

The earlier versions kept everything in `roles/devices/vars/main.yml` (Linux) or `roles/mac-devices/vars/main.yml` (macOS), and the images and the options of Appium in `defaults/main.yml` (now `versions.yml` and `roles/common/defaults/main.yml`). Such a `vars/main.yml` overrides `config/`, so the deploy and `./zebrunner.sh doctor` refuse it. `./zebrunner.sh migrate` moves them: it shows the changes of `config/` (the secrets hidden) and asks first, then writes the settings that differ from the ones the deploy has already into `config/settings.yml` and the `devices:` into `config/devices.yml` (the previous files are kept as `*.bak`), and renames the files of the earlier version to `*.migrated`. With a local change of `defaults/main.yml`, `git pull` stops: keep a copy, drop the change, pull, then migrate the copy:

```bash
cp defaults/main.yml defaults.local.yml && git checkout defaults/main.yml && git pull
./zebrunner.sh migrate defaults.local.yml
```

## Node enrollment

Every device host joins [MCloud](https://github.com/zebrunner/mcloud#nodes) with its own token: the administrator of MCloud invites it, the host enrolls itself, no secret is copied by hand.

1. On the MCloud server: `./zebrunner.sh node-invite <label> <address>`. The label is the name of the host (`a-z`, `0-9`, `-`), the address is the one the MCloud server connects to: the hub registers the Appium nodes by it, stf-proxy takes the screens from it (in the network of the MCloud server the address there, see [Device hosts in a private network](#device-hosts-in-a-private-network); on the MCloud server itself its LAN address, see [Devices on the MCloud server](#devices-on-the-mcloud-server)). With the [WireGuard tunnel](#wireguard-tunnel) of MCloud on, the invite has no address (`./zebrunner.sh node-invite <label>`): MCloud gives the host an address of the tunnel. It prints a join string, valid once and for a limited time; a new invite of the label replaces it.
2. On this host: `./zebrunner.sh join` asks for the join string (hidden; or on stdin: never in the command line, where it stays in the shell history) and enrolls the host:
   - it makes the CURVE key of the host if there is none and sends its public key, never the secret one;
   - it makes a new WireGuard key pair of the host and sends its public key (`wgPublicKey`, MCloud without the [WireGuard tunnel](#wireguard-tunnel) ignores it); the private key is written to the settings only when MCloud has the tunnel on;
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
| `WG_ENABLED`, `WG_PRIVATE_KEY`, `WG_ADDRESS`, `WG_SERVER_ADDRESS`, `WG_SERVER_PUBLIC_KEY`, `WG_ENDPOINT`, `WG_NETWORK`, `WG_PERSISTENT_KEEPALIVE` | the [WireGuard tunnel](#wireguard-tunnel) to MCloud when MCloud has it on, otherwise not written (a join of MCloud without the tunnel turns off the tunnel of an earlier join: `WG_ENABLED: false`, the others empty) |

`REMOTE_CONNECT_HOST` is set by hand when needed, see [Device hosts in a private network](#device-hosts-in-a-private-network).

Security:

- the token is of this host only: MCloud keeps its hash, binds it to the address of the host and to its devices, and revokes it alone (`./zebrunner.sh nodes revoke <label>` of mcloud);
- `config/settings.yml` and the deployed settings of `zebrunner-farm` (`/usr/local/etc/zebrunner-farm.env`) have the secrets of the host: `config/settings.yml` is mode 600, the settings of `zebrunner-farm` are readable by root and the user of the deploy only (Linux: mode 640, the group of the user; macOS: mode 600, the user); the script `zebrunner-farm` has no secret and passes them to docker in its environment (`-e NAME` without the value), not in its arguments that every local user sees (`ps`); the users of the `docker` group can read the variables of the containers anyway, they are root on the host;
- a new join string (`node-invite` of the same label) replaces the token and the key of the host: run `./zebrunner.sh join` again to rotate them;
- `./zebrunner.sh doctor` asks MCloud about this host (enrolled, active, its address, the devices STF knows and binds to it) and reports the settings readable by other users.

## Run ansible playbook

- `./zebrunner.sh ansible` runs `agent.yml` on both OS: its first play groups the hosts by their OS (`os_Linux`, `os_Darwin` of `hosts`), the next ones deploy the role of each OS.
- The images of the devices are pinned in `versions.yml`: `DEVICE_VERSION` (mcloud-device), `APPIUM_VERSION`, `IOS_CONNECTOR_VERSION`, `ANDROID_CONNECTOR_VERSION` and `UPLOADER_VERSION`. mcloud-device must be the one of the STF of [mcloud](https://github.com/zebrunner/mcloud) (`TAG_STF` of its `.env`). Another version is a line of `config/settings.yml` (see [Settings](#settings)). On `develop` they are `<version>-develop-latest`, the newest image of the `develop` of each repository (`UPLOADER_VERSION` is a release, artifacts-uploader has no such image); the deploy pulls them again, a release pins its versions.
- [Optional] To compare images in the tests (the Appium images plugin) appium needs the image of its `appium-image` stage, the `-img` postfix of its version. It is not published: build it with [appium](https://github.com/zebrunner/appium#build) (`make build VERSION=3.1.1-img TARGET=appium-image`) on every device host (the deploy keeps a local image it cannot pull) or push it to a registry of yours, and set it in `config/settings.yml`:

  ```yaml
  APPIUM_IMAGE: registry.example.com/zebrunner/appium
  APPIUM_VERSION: 3.1.1-img
  ```

  > The published appium images: <https://gallery.ecr.aws/zebrunner/appium>

### Linux OS

- update `config/settings.yml` and `config/devices.yml` files according to the obligatory/optional comments inside (see [Settings](#settings)).
  > Register all whitelisted Android and iOS devices with their udids!
  > The deploy validates the devices: obligatory settings, the characters of the ids, names and locations (letters, digits, `_`, `.`, `-`), unique ids and names, the size of `min_port`-`max_port` (4 ports of an Android device besides `connect_port`), and host ports (`appium_port`, `min_port`-`max_port`, `connect_port`) not shared by devices. `adb_port` is not used on Linux; `connect_port` (optional, Android) is the remote debug port of STF.
- Run ansible-playbook script to download the required components (the connector of the platforms of the registered devices only) and set up udev rules:

  ```bash
  ./zebrunner.sh ansible
  ```

  > To deploy again without the download of the images, e.g. after a change of `config/devices.yml`, use the command below. It runs the whole role of the OS (the checks, `zebrunner-farm` and its settings, the list of the devices, the udev rules and the systemd units) and keeps the running containers of the devices: `zebrunner-farm restart <devices>` creates them with the new settings.

  ```bash
  ./zebrunner.sh ansible devices
  ```

  > The arguments after `ansible` or `ansible devices` are passed to ansible-playbook, e.g. `-vvv`; a run that changes nothing (`--check`, `--syntax-check`, `--list-tasks`) does not offer to remove the running containers. The agent is deployed for the user who runs `./zebrunner.sh` (the inventory `hosts` connects locally, the files and the launch agents are of its `USER` and `HOME`), so `--user` has no effect: run it as that user. The sudo password is asked interactively: do not pass it in the command line, where it stays in the shell history and is visible in the processes list.

  ```bash
  ./zebrunner.sh ansible devices -vvv
  ```

- Running containers of the devices keep the settings and the images they were created with: `./zebrunner.sh ansible` lists them and offers to remove them first (`zebrunner-farm down`, Enter is yes), otherwise run `zebrunner-farm restart` after the deploy.
- Run `zebrunner-farm start` to create the containers of the devices connected before the deploy and of the wireless, emulator and proxy devices: udev starts the containers of a USB device on its next connection only.
- Devices management script is deployed to /usr/local/bin/zebrunner-farm (the same script on Linux and macOS), its settings to /usr/local/etc/zebrunner-farm.env (see [Settings](#settings)).
- Udev rules with whitelisted devices are in /etc/udev/rules.d/90_mcloud.rules: a connection of a USB device starts the systemd unit `mcloud-device-restart@<id>`, a disconnection `mcloud-device-down@<id>` (`/etc/systemd/system`), which run `zebrunner-farm restart` or `down` for it. udev only queues the job: its programs are killed after the event (180 s), the containers may need longer (the images are pulled). A disconnection cancels an unfinished restart and the other way round.
- The commands of one device (`zebrunner-farm start`, `stop`, `restart`, `down` of the device or of a group with it, the units of udev) run one at a time (`flock`, `/run/lock/mcloud-device-<id>.lock`): one waits for up to 30 minutes for another, a group takes its devices one by one.
- Whitelisted devices properties are in /usr/local/bin/mcloud-devices.txt, rendered from `config/devices.yml`: one device per line, its fields `key=value` (the keys of `config/devices.yml`) separated by `|`; an empty value is the value by default (`wda_file`, `wda_bundleid`: `WDA_FILE`, `WDA_BUNDLEID` of the settings).
- Usbmuxd service is stopped and masked (disabled).
- Wireless, emulator and proxy devices have no udev rules: `zebrunner-farm start` creates their containers.
- Android emulators (`android-sim`) are started outside the farm (e.g. an AVD, Genymotion, a container Android): set `address` to their adb address reachable from the docker network; appium gets `DEVICE_CONNECTION=android-sim` (a `default` device is a phone).
- [Optional] The containers of all the devices after a reboot: `./zebrunner.sh autostart enable`, see [Autostart](#autostart).
- [Optional] Increased `fs.inotify.max_user_instances` to workaround [#328](https://github.com/zebrunner/mcloud-agent/issues/328)
  > `sudo sysctl fs.inotify.max_user_instances=2048`

### Mac OS

- update `config/settings.yml` and `config/devices.yml` files according to the obligatory/optional comments inside (see [Settings](#settings)).
  > Register all whitelisted Android and iOS devices (phones, tablets, TVs or simulators) with their udids and connections!
  > The deploy validates the devices: obligatory settings, the characters of the ids, names and locations (letters, digits, `_`, `.`, `-`), unique ids and names, the size of `min_port`-`max_port` (4 ports of an Android device besides `connect_port`), the connections, host ports (`appium_port`, `min_port`-`max_port`, `connect_port`, `wda_port` and `mjpeg_port` of the iOS simulators, `adb_port` of the USB Android devices) not shared by devices.
- Run ansible-playbook script to download the required components (the connector of the platforms of the registered devices only) and set up launchd agents:

  ```bash
  ./zebrunner.sh ansible
  ```

  > To deploy again without the download of the images, e.g. after a change of `config/devices.yml`, use the command below. It runs the whole role of the OS (the checks, `zebrunner-farm` and its settings, the list of the devices, the launch agents) and keeps the running containers of the devices: `zebrunner-farm restart <devices>` creates them with the new settings.

  ```bash
  ./zebrunner.sh ansible devices
  ```

  > The arguments after `ansible` or `ansible devices` are passed to ansible-playbook, e.g. `-vvv`; a run that changes nothing (`--check`, `--syntax-check`, `--list-tasks`) does not offer to remove the running containers. The agent is deployed for the user who runs `./zebrunner.sh` (the inventory `hosts` connects locally, the files and the launch agents are of its `USER` and `HOME`), so `--user` has no effect: run it as that user. The sudo password is asked interactively: do not pass it in the command line, where it stays in the shell history and is visible in the processes list.

  ```bash
  ./zebrunner.sh ansible devices -vvv
  ```

- Devices management script is deployed to /usr/local/bin/zebrunner-farm (the same script on Linux and macOS), its settings to /usr/local/etc/zebrunner-farm.env (see [Settings](#settings)).
- The containers run on the platform of the Mac, arm64 on Apple Silicon (the STF provider of an iOS simulator hangs under emulation, the other ones are slower), but appium: its image is `linux/amd64` only (see [appium](https://github.com/zebrunner/appium#limitations)), emulated by Docker Desktop with Rosetta 2 on Apple Silicon.
- Whitelisted devices properties are in /usr/local/bin/mcloud-devices.txt, rendered from `config/devices.yml`: one device per line, its fields `key=value` (the keys of `config/devices.yml`) separated by `|`; an empty value is the value by default (`wda_file`, `wda_bundleid`: `WDA_FILE`, `WDA_BUNDLEID` of the settings).
- Deployed and loaded $HOME/Library/LaunchAgents/ZebrunnerUsbmuxd.plist to share usbmuxd into the device containers: socat on localhost of the Mac, on the port of `USBMUXD_SOCKET_ADDRESS` (`host.docker.internal:2222` by default) the containers reach it with
- USB Android devices: deployed and loaded $HOME/Library/LaunchAgents/ZebrunnerAdb.plist, the adb server of the host (`brew install android-platform-tools`) on the port of `ADB_SERVER_SOCKET_ADDRESS` (`host.docker.internal:5037` by default); the connectors take the devices from it, the containers of a USB Android device are created by `zebrunner-farm start` (the devices listener handles iOS only).
- iOS simulators (`ios-sim`): the ssh key of the agent is generated into `ssh/id_ed25519` of the agent folder and authorized in `~/.ssh/authorized_keys` (`restrict`), turn on Remote Login (System Settings, General, Sharing) for the user. Set the simulator build of WebDriverAgent (`WDA_SIMULATOR_FILE` or `wda_file` of the device), e.g. `WebDriverAgentRunner-Build-Sim-arm64.zip` of [appium/WebDriverAgent](https://github.com/appium/WebDriverAgent/releases).
- Deployed $HOME/Library/LaunchAgents/ZebrunnerDevicesListener.plist to load and manage iOS devices connect/disconnect automatically: the devices listener (/usr/local/bin/zebrunner-device-listener and usbmuxd_watch) restarts the containers of a connected USB device and removes them on disconnect, devices reachable over Wi-Fi only are not handled by it.
- Log rotation of the devices listener log is set up in /etc/newsyslog.d/zebrunner-mcloud.conf.
- Run `zebrunner-farm start` to create the containers of the connected devices and to load the devices listener (otherwise it is loaded on the next login only).

## Agent management

`./zebrunner.sh` without arguments (or `help`, `--help`, `-h`) lists its commands, grouped by stage: set up, operate, maintain, help. `./zebrunner.sh help <command>` (or `./zebrunner.sh <command> --help`, `-h`) shows the usage, the description and the options of a command without running it: `-h` or `--help` anywhere in the arguments of a command shows its help, so `./zebrunner.sh ansible --check --help` deploys nothing (`ansible-playbook --help` shows the options of ansible-playbook). An unknown command is an error with the closest commands (`Did you mean: status?`) and the usage on stderr, its exit code is 2. Its output has the terminal style of every MCloud repository (`patch/ui.sh`, [CONVENTIONS.md](CONVENTIONS.md#terminal-output)): colors on a terminal only (`NO_COLOR`, `UI_COLOR=always` or `never`), the Unicode glyphs with a UTF-8 locale (`UI_ASCII=true` for ASCII); without a terminal it is plain text. The commands:

- `setup` - prepares the agent: the settings of `config/` from the examples. It changes no shell profile: `zebrunner.sh` knows its folder, `zebrunner-farm` has it in its settings, so `zebrunner-farm ansible` deploys again from any folder; the `ZEBRUNNER_MCLOUD_AGENT_DIR` line of the earlier versions is removed from the profiles.
- `ansible [devices] [arguments]` - deploys the agent, `devices` without the download of the images and keeping the running containers of the devices, the arguments are of ansible-playbook (see [Run ansible playbook](#run-ansible-playbook)).
- `status` - shows the state of the agent components: tools, Rosetta 2 of an Apple Silicon Mac, deployed files, launch agents.
- `backup` and `restore` - save the settings of `config/` into the `backup` folder and restore them from it (see [Settings](#settings)); a backup of an earlier version (`vars/main.yml`, `defaults/main.yml`) goes to `config/` with `./zebrunner.sh migrate <its files>`.
- `shutdown` - removes the devices containers, the docker volumes of the agent (`device-*`: the logs and the pair records of the iOS devices, `devimages_cache`, `mcloud-key-volume`: the adb key of the host, so the devices ask to trust the host again after a new setup), the launch agents or udev rules, the deployed files (also the bash completion of `zebrunner-farm`), the settings, the ssh key of the simulators (and its line of `~/.ssh/authorized_keys`), the [WireGuard tunnel](#wireguard-tunnel) and the environment variable (asks for confirmation).
- `version` - shows the versions of the agent components: a `NAME: value` line each on stdout (`DEVICE_VERSION: 3.1.2`), the header and the footer on stderr, so `./zebrunner.sh version 2> /dev/null` is the data only.
- `doctor` - checks the host, the settings, the deployment, the network to the MCloud server and the devices, and tells what to fix, see [Doctor](#doctor).
- `join` - enrolls this host in MCloud with the join string of `./zebrunner.sh node-invite` of mcloud, see [Node enrollment](#node-enrollment).
- `migrate [files...]` - moves the settings of an earlier version to `config/`, see [Settings](#settings).
- `autostart [status|enable|disable]` - the containers of the devices after a reboot, off by default, see [Autostart](#autostart).
- `mdm <status|enroll|release|supervise> [devices...] [options]` - the devices in the MDM of MCloud, see [MDM](#mdm).
- `help [command]` - the commands, or the help of a command.
- `completion bash|zsh` - the completion of the shell, see [Completion](#completion).

### Completion

`./zebrunner.sh` and `zebrunner-farm` complete their commands, the actions (`mdm status|enroll|release|supervise`, `autostart status|enable|disable`), the options (`--help`, `-x`, `--uninstall`, the options of ansible-playbook after `./zebrunner.sh ansible -`) and the devices of this host (their udids and names, the groups `ios`, `android`, `usb`, ...) with the TAB key of bash and zsh; the arguments of `migrate` are files. The devices are the deployed ones (the list of `zebrunner-farm`), before the first deploy the ones of `config/devices.yml`.

- bash, `./zebrunner.sh`: add to `~/.bashrc` (`./zebrunner.sh help completion` prints the line with the folder of the agent):

  ```bash
  eval "$(/path/to/mcloud-agent/zebrunner.sh completion bash)"
  ```

- bash, `zebrunner-farm`: the deploy (`./zebrunner.sh ansible`) installs the completion for every user of the host: `/etc/bash_completion.d/zebrunner-farm` on Linux, `$(brew --prefix)/etc/bash_completion.d/zebrunner-farm` on macOS with Homebrew. bash-completion loads it (`apt install bash-completion`, `brew install bash-completion` and its line in `~/.bash_profile`); without the folder of bash-completion the deploy installs nothing. It completes `./zebrunner.sh` too. `./zebrunner.sh shutdown` removes it.
- zsh (both, through `bashcompinit`): add to `~/.zshrc`, after `compinit` when it has one:

  ```bash
  eval "$(zebrunner-farm completion zsh)"
  ```

  or `eval "$(/path/to/mcloud-agent/zebrunner.sh completion zsh)"`.

The completion is safe at any folder: it runs only a `zebrunner.sh` (or `zebrunner-farm`) of the current user or of root that the group and the others cannot write, so a TAB in a strange folder does not run its `zebrunner.sh`; and `<program> __complete <index> <words...>`, the question of the completion, answers at once and changes nothing: no docker, no network, no file written, no question, no secret printed ([CONVENTIONS.md](CONVENTIONS.md#completion)).

### Autostart

The deploy adds no autostart. After a reboot the USB devices are started by udev (Linux) and by the devices listener at the login (iOS of macOS); the containers of the other devices (wireless, emulators, proxy; the USB Android devices of macOS) stay stopped: `zebrunner-farm start` starts them. The autostart is a choice of the administrator of the host, off by default:

- `./zebrunner.sh autostart` shows whether it is on.
- `./zebrunner.sh autostart enable` tells what it adds, shows the content of the file and asks first (No by default); nothing starts at once:
  - Linux: the systemd unit `/etc/systemd/system/mcloud-farm.service` (sudo, `systemctl enable`), it runs `zebrunner-farm start --quiet` once after docker (and the [WireGuard tunnel](#wireguard-tunnel) when there is one) at the boot; its log: `journalctl -u mcloud-farm`;
  - macOS: the launch agent `~/Library/LaunchAgents/ZebrunnerFarmStart.plist` of the user (no sudo), at the login it waits for Docker Desktop and, when it is on, for the [WireGuard tunnel](#wireguard-tunnel) (10 minutes at most: let Docker Desktop start at the login) and runs `zebrunner-farm start --quiet` once; its log: `logs/autostart.log` of the agent folder.
- `./zebrunner.sh autostart disable` tells what it removes and asks first; the running containers keep running. `./zebrunner.sh shutdown` removes it too.

### WireGuard tunnel

MCloud can keep all the flows between it and its device hosts in a WireGuard tunnel (`NODES_WIREGUARD=true` of [mcloud](https://github.com/zebrunner/mcloud), off by default; it needs the WireGuard counterparts of mcloud and STF): ZeroMQ, the grid registration, the grid to Appium, the screens and the remote debug of the adb relay. MCloud then publishes its ports of the nodes (4446, 7250, 7270) on its address in the tunnel only, and this host publishes the ports of its devices (`appium_port`, `min_port`-`max_port`, `connect_port`) on its address in the tunnel only: no device port is open on the other networks of the host. The users (STF, `PUBLIC_IP`), `MCLOUD_URL` of the join (HTTPS, pinned) and the iOS devices to the MDM stay on the public network.

- The administrator of MCloud invites the host without an address (`./zebrunner.sh node-invite <label>`): MCloud gives it an address of its WireGuard network (`NODES_WG_NETWORK`, `10.234.0.0/24` by default, MCloud is the first one). `./zebrunner.sh join` sends the public key of a new WireGuard key pair of the host (made in Python as the CURVE key, the private key never leaves the host) and writes the answer:

  | Setting | Value |
  | --- | --- |
  | `WG_ENABLED` | `true`; `false` (the default) or missing: no tunnel, nothing of this section is deployed |
  | `WG_PRIVATE_KEY` | the private WireGuard key of this host (a secret: `config/settings.yml` is mode 600, the config of wg-quick root only) |
  | `WG_ADDRESS` | the address of this host in the tunnel, also `STF_PROVIDER_HOST` |
  | `WG_SERVER_ADDRESS` | MCloud in the tunnel: `SELENIUM_HUB_HOST` and the host of `STF_PROVIDER_CONNECT_*` |
  | `WG_SERVER_PUBLIC_KEY`, `WG_ENDPOINT` | the public WireGuard key of MCloud and its UDP endpoint (`<host of the join string>:<NODES_WG_PORT>`, 51820 by default): open it in the firewall of MCloud |
  | `WG_NETWORK` | the network of the tunnel |
  | `WG_PERSISTENT_KEEPALIVE` | the keepalive of this host in seconds (25), it keeps the NAT of the host open |

- `./zebrunner.sh ansible` sets up the interface `mcloud-node` (wg-quick, `/etc/wireguard/mcloud-node.conf`, mode 600, root; only `WG_SERVER_ADDRESS/32` goes through it), up at the boot:
  - Linux: `wireguard-tools` of apt, the unit `wg-quick@mcloud-node` enabled and started (a try ends after 90 seconds, it tries again every 10 seconds when it fails, e.g. the name of the endpoint does not resolve yet at the boot), the units of the devices start after it;
  - macOS: `wireguard-tools` and `wireguard-go` of Homebrew (`brew install` as the user), the launch daemon `/Library/LaunchDaemons/com.zebrunner.wireguard.plist` runs `wg-quick up /etc/wireguard/mcloud-node.conf` at the boot (its log: `/var/log/zebrunner-wireguard.log`).
- The boot: the containers of the devices publish their ports on `WG_ADDRESS`, which exists once the interface is up (docker cannot publish a port on an address the host does not have yet), so the deploy orders them:
  - Linux: the drop-in `/etc/systemd/system/docker.service.d/zebrunner-wireguard.conf` starts docker after `wg-quick@mcloud-node` (`Wants=`, `After=`; it applies at the next boot, the deploy does not restart docker), so the containers docker restarts at the boot, the USB devices of udev and the [autostart](#autostart) find the address; docker waits for one try of `wg-quick` (90 seconds at most). When the interface comes up later (a later try), `wg-quick@mcloud-node` starts the unit `mcloud-wireguard-up` (`/etc/systemd/system/mcloud-wireguard-up.service`, its log: `journalctl -u mcloud-wireguard-up`): it runs `zebrunner-farm start` for the devices whose containers docker could not start on `WG_ADDRESS` (their error of docker names the address); the containers stopped by a person and the removed ones stay as they are.
  - macOS: the launch daemon brings the interface up at the boot, Docker Desktop starts at the login of the user, after it: the devices listener and the autostart start the containers then; the autostart also waits for the address. When the tunnel came up after Docker Desktop (no network at the boot), `zebrunner-farm start` starts the devices that failed.
- A node on the MCloud server itself works too (see [Devices on the MCloud server](#devices-on-the-mcloud-server)): its interface is `mcloud-node`, the one of the head is `mcloud`; `WG_SERVER_ADDRESS` is then also a local address of the machine (of the interface of the head).
- Without `WG_ENABLED: true` the deploy stops and removes the tunnel of an earlier deploy (its config, the unit or the launch daemon, the order of docker after it and `mcloud-wireguard-up`; wireguard-tools stays) and changes nothing on a host that never had it.
- `zebrunner-farm` publishes the ports of the devices as `-p <WG_ADDRESS>:<port>:<port>` (the env file of the deploy has `WG_ENABLED` and `WG_ADDRESS`); a change needs `./zebrunner.sh ansible` and `zebrunner-farm restart`. The interface must be up first: docker cannot publish a port on an address the host does not have (see the boot above).
- `./zebrunner.sh doctor` checks the tunnel: the interface is up with `WG_ADDRESS`, the last handshake with MCloud is less than 3 minutes old (`wg show` needs root: with sudo without a password only, otherwise it tells to run `sudo wg show`), mcloud-grid answers at `WG_SERVER_ADDRESS`, `STF_PROVIDER_HOST` is `WG_ADDRESS`.
- A new join string of MCloud with the tunnel off turns it off here too (`./zebrunner.sh join`, `./zebrunner.sh ansible`, `zebrunner-farm restart`); `./zebrunner.sh shutdown` removes it.

### ZeroMQ security

STF of MCloud accepts on its ZeroMQ ports only the enrolled device hosts: the CURVE key of every host is in the registry of MCloud. `./zebrunner.sh join` makes the key of this host (`STF_ZMQ_CURVE_SECRET_KEY`, kept when it is set), sends its public key and writes the public key of the server (`STF_ZMQ_CURVE_SERVER_PUBLIC_KEY`); a revocation of the host on the MCloud server disconnects it. `patch/curve_keygen.py` makes the keys with Python only (X25519 of RFC 7748), the same as `stf curve-keygen`.

### Doctor

`./zebrunner.sh doctor` (or `zebrunner-farm doctor` from any folder) checks the agent and tells what to fix, it changes nothing and prints no secret:

- the host: docker, ansible, python3, lsusb (Linux), Rosetta 2 (Apple Silicon);
- the YAML of `config/settings.yml` and `config/devices.yml`: doctor reads the settings as the playbooks load them (the values by default of the roles, `versions.yml`, `config/settings.yml`), a file that is not valid YAML is a problem;
- the settings of `config/settings.yml`: the ones of `./zebrunner.sh join`, the formats of the token and of the CURVE keys, the file readable by other users, a `roles/.../vars/main.yml` of an earlier version; the devices of `config/devices.yml` with the checks of the deploy (unique ids and names, the obligatory settings, the characters of the ids, names and locations, the size of the port ranges, the host ports, the connections of the OS);
- the enrollment: it asks MCloud about this host (`GET /api/v1/nodes/self` of `MCLOUD_URL` with the token, over HTTPS to the pinned TLS key): enrolled and active (or unknown, revoked), its address in MCloud is `STF_PROVIDER_HOST`, the devices STF knows of it, which of them are bound to it and connected;
- the deployment: the settings of `zebrunner-farm` (`/usr/local/etc/zebrunner-farm.env`) are the ones of this folder and the current ones, also the versions of the images (otherwise `./zebrunner.sh ansible`) and readable by this user only, the containers created with the current `STF_PROVIDER_HOST` (otherwise `zebrunner-farm restart`);
- the [WireGuard tunnel](#wireguard-tunnel) with `WG_ENABLED: true`: the interface `mcloud-node` up with `WG_ADDRESS`, a handshake with MCloud within 3 minutes (`wg show` needs root: sudo without a password, otherwise reported as not checked), mcloud-grid answers at `WG_SERVER_ADDRESS`, `STF_PROVIDER_HOST` is `WG_ADDRESS`;
- the network: the name resolution and the ports of `PUBLIC_IP`, mcloud-grid and the ZeroMQ triproxies; `STF_PROVIDER_HOST` is an address of this host, or a public address of a NAT while the MCloud server is in the network of this host (see [Device hosts in a private network](#device-hosts-in-a-private-network)); MCloud on this machine and the devices using its ports (see [Devices on the MCloud server](#devices-on-the-mcloud-server));
- the remote debug: with `REMOTE_CONNECT_HOST` the adb relay of mcloud accepts the remote debug ports of the Android devices (printed);
- the devices: their containers, the refused grid registrations of Appium and the refused CURVE key in the logs of the last 30 minutes.
- the USB (Linux): the USB devices of the farm that are not on USB, with their last port (see [USB map](#usb-map)), and the USB ports that flapped in the last 7 days, a warning each with the verdict, see [USB stability](#usb-stability).

The MCloud server checks a host too: `./zebrunner.sh nodes check <label>` of [mcloud](https://github.com/zebrunner/mcloud#nodes) shows its record, its devices and whether the server reaches their screens.

Every check is a line: a green, amber or red dot on a terminal (`ok`, `warn`, `FAIL` without colors), a muted circle (`info`) for a fact, and `fix` under a problem; the last lines count them (`12 ok, 1 warn, 0 fail` without colors) and tell what to do. It exits with `1` when a check fails.

### TLS of MCloud

The containers of STF of the devices talk to MCloud over https (`PUBLIC_IP`, the storage and the API) and verify its certificate. The deploy (`patch/tlstrust.py`) finds which one they trust:

- a certificate of a public CA valid for `PUBLIC_IP`: nothing to do, the containers trust it already;
- otherwise (a self-signed certificate): the certificates the server sends, only when their key is the pinned one of the join string (`MCLOUD_TLS_PIN`) and they are valid for `PUBLIC_IP`; `zebrunner-farm` passes them to the containers in `MCLOUD_CA_PEM` (`NODE_EXTRA_CA_CERTS` of mcloud-device);
- another key, a certificate of another name or no server: the deploy stops with the reason. Use the name or the address of the certificate in `PUBLIC_IP`; for a self-signed certificate of another name only, `STF_TLS_INSECURE: true` of `config/settings.yml` turns the verification off (`NODE_TLS_REJECT_UNAUTHORIZED=0`), anyone in the path then reads the node token and changes the apps installed on the devices.

`./zebrunner.sh doctor` runs the same check. A new certificate of MCloud: a public one needs nothing, a new self-signed one `./zebrunner.sh ansible` and `zebrunner-farm restart` (a new TLS key: a new join string).

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
- the ports of the devices (`appium_port`, `min_port`-`max_port`, `connect_port`) are not the ports of MCloud: its HTTPS port (`STF_PORT`), 4446 (mcloud-grid), 7160, 7250, 7260, 7270 (the triproxies of STF) and the remote debug ports of the adb relay (`ADB_RELAY_PORTS` of mcloud); `./zebrunner.sh doctor` reports the collisions with the HTTPS port, the hub and the triproxies, not with `ADB_RELAY_PORTS`, which it does not know: keep them out of the ranges of the devices of this machine.

### Grid registration

The Appium node of a device registers in mcloud-grid with the token of this host (`MCLOUD_NODE_TOKEN`, passed to appium as `NODE_REGISTRATION_TOKEN`): the hub accepts it only when STF knows the token of an active host whose address is the host of the node url (`STF_PROVIDER_HOST`), checks it again every minute and sends it back to this node only with every request, see [mcloud-grid](https://github.com/zebrunner/mcloud-grid#node-registration). A revoked host is unregistered.

### Docker network

Every device has a docker network of its own (`DEVICE_NETWORK_ISOLATION: true`, the default), named as its containers and its volume (`device-<name>-<udid>`): its connector, stf, appium and uploader are on it and on no other network. The ports of a connector are open to its network without authentication (the adb server of an Android device; usbmuxd `2222`, WebDriverAgent and MJPEG, the go-ios tunnel API and port of an iOS device, [mcloud-ios-connector](https://github.com/zebrunner/mcloud-ios-connector#network)), as are the screen broadcast (`2223`) and VNC of its stf container: with a network per device only the containers of that device reach them, not the containers of the other devices, of mcloud on the same machine or of other projects. The containers reach MCloud by its published ports (`PUBLIC_IP`, `SELENIUM_HUB_HOST`, the triproxies), and the internet through the NAT of docker, as before.

- `zebrunner-farm start` creates the network of a device with a free `/28` of `DEVICE_NETWORK_SUBNETS` (`10.233.0.0/16` by default, 4096 devices; a subnet of another docker network is skipped), not of the address pools of docker, which give about 30 networks and may overlap the networks of the sites. Set another range when `10.233.0.0/16` is routed in your network. `zebrunner-farm down` removes the network.
- The container of the emulator or the simulator of an `android-sim` or `proxy` device, when the host of its `address` is a container of this host (e.g. `mcloud-dummy` of `mcloud-dummy:15555`), joins the network of the device.
- A network costs a Linux bridge and a few rules of docker: hundreds of devices on a host are fine.
- The other services the containers use, e.g. `S3_ENDPOINT` of the uploader (a MinIO on this host), are reached by an address and a published port, as MCloud: a name of a container of `STF_DOCKER_NETWORK` (`http://minio:9000`) does not resolve on the network of a device, the uploads fail.
- `DEVICE_NETWORK_ISOLATION: false`: the containers of all the devices share `STF_DOCKER_NETWORK` (`infra` by default), which is then trusted: attach only the containers of the farm to it.

The containers of a device created before keep their network until they are created again (`zebrunner-farm down` and `start`; `./zebrunner.sh ansible` asks to remove them before the deploy).

### Appium security

The Appium port of a device (`appium_port`) is published on the host for mcloud-grid. Appium of the device answers only the requests of the grid, which carry the token of this host, and the ones of its own container: the others get `401` (also Appium Inspector and the WebSockets of the sessions, e.g. the logcat broadcast; use the grid, `/mcloud/wd/hub` of mcloud).

`APPIUM_RELAXED_SECURITY` of `roles/common/defaults/main.yml` is `false`: a session does not get the blanket insecure features of Appium. In particular `get_server_logs` is off, so one session cannot read the Appium log of the earlier sessions of the device (another user's capabilities and inputs). The features the tests usually need are enabled granularly instead: `APPIUM_ADB_SHELL` (`true` by default) for `mobile: shell` (adb shell of the device) and `APPIUM_CHROMEDRIVER_AUTODOWNLOAD` (`true` by default) for the automatic download of the matching chromedriver of the web and hybrid tests. Set `APPIUM_RELAXED_SECURITY: true` in `config/settings.yml` only for a feature not covered by those (the emulator console, the screen streaming, `get_server_logs`).

### Cleanup

When a device is released (the end of a test session, a user of STF leaves it), the STF container of the device uninstalls the apps installed since the container started, so the next user does not get the apps, logins and files of the previous one ([mcloud-device](https://github.com/zebrunner/mcloud-device), Android and iOS). The apps the device had at the start stay, WebDriverAgent stays, and so do the helpers of the farm installed later (the UiAutomator2 server and the settings of Appium, the agent and the apps of the MDM). The accounts of the device (e.g. Google) and the data of the apps that stay are not reset. A cleanup stops uninstalling once the device is used again.

| Setting of `config/settings.yml` | Default | Description |
| --- | --- | --- |
| `STF_PROVIDER_CLEANUP` | empty | empty: the default of mcloud-device (on); `false`: the apps stay from use to use (e.g. a host whose tests expect an app installed once); `true` |
| `CLEANUP_KEEP_PACKAGES` | empty | more apps the cleanup keeps on this host: Android packages or iOS bundle ids, or prefixes ending with `*`, separated by commas, e.g. `com.example.preinstalled,com.example.tools.*` |

A change needs `./zebrunner.sh ansible` and `zebrunner-farm restart`. The apps of the start are the ones the device has when its container starts: install an app that must stay before `zebrunner-farm restart`, or list it in `CLEANUP_KEEP_PACKAGES`.

### Port forwarding

The port forwarding of STF (a port of the device to a host and a port the user gives, Android) connects from this host. It reaches public addresses only: a private, loopback, link-local or metadata address (also the ones a host name resolves to) is refused, so a user cannot reach the services, the docker networks or the LAN of this host through a device.

| Setting of `config/settings.yml` | Default | Description |
| --- | --- | --- |
| `STF_FORWARD_ALLOW` | empty | the networks the forwards may reach besides the public addresses, CIDRs or addresses separated by commas, e.g. the LAN of the users `192.168.10.0/24` |

A change needs `./zebrunner.sh ansible` and `zebrunner-farm restart`.

### Recordings

With S3 (`S3_BUCKET` and the other `S3_*` settings of `config/settings.yml`) appium records the video of every session and the uploader container of the device uploads it with the logs of the session to `s3://<S3_BUCKET>[/<S3_TENANT>]/artifacts/test-sessions/<session id>/`. Without `S3_BUCKET` appium records no video (`RECORD_ARTIFACTS=false`) and the device has no uploader: there is nothing to upload to, the videos filled the disk. Appium still keeps the log of every session in a folder of the volume of the logs of the device, the volume is removed with the containers (`zebrunner-farm restart`, `down`, a disconnection of a USB device). A change of S3 needs `./zebrunner.sh ansible` and `zebrunner-farm restart`.

### Devices management

`zebrunner-farm <command> [devices...] [options]` manages the containers of the devices: `status`, `start` (creates the missing containers, starts the stopped ones, keeps the running ones), `stop`, `restart` (removes and creates them again) and `down` (removes them); `logs`, `shell` and `exec` help to debug a device; `./zebrunner.sh mdm` is the [MDM](#mdm) of a device. `zebrunner-farm help` lists the commands, `zebrunner-farm help <command>` (or `<command> --help`) shows the options and examples of one; an unknown command suggests the closest ones and exits with `2`.

- `restart` of several devices has two strategies: `--batch` (the default, `--strategy batch`) removes the containers of all the devices one by one, then creates and starts them; `--rolling` (`--strategy rolling`) removes and creates the containers device by device, the other devices keep working meanwhile. The question of a terminal shows the strategy, `s` switches it.

- The devices are udids or names, groups (`ios`, `android`, `usb`, `wireless`, `android-sim`, `ios-sim`, `proxy`) or patterns of the udids, names and locations in quotes (`'Samsung_*'`), several ones separated by spaces or commas; all the devices without them. A udid or a name of no device suggests the closest names, udids and groups.
- `-x` (`-e`, `--exclude`, also `-x=<devices>`) skips devices, groups or patterns, e.g. `zebrunner-farm restart android -x Pixel_8_Pro -x 'Samsung_Galaxy_S2?'`.
- `--dry-run` (`start`, `stop`, `restart`, `down`) shows what the command would do for every device and container (`would create`, `would start`, `would stop`, `would remove`) from the states of `docker ps -a`: no container, volume, network or launch agent is changed, no lock is taken, nothing is asked; the status is `0`.
- In a terminal `start`, `stop`, `restart` and `down` of a group show the numbered devices with the state of their containers and ask: Enter or `y` runs the command, `n` cancels, `f <devices>` keeps only these devices of the list, `x <devices>` excludes them, `p` picks them with [fzf](https://github.com/junegunn/fzf) (`TAB` marks several; shown when fzf is installed); `<devices>` are the numbers of the list, udids, names, groups or patterns. `-q` (`--quiet`) runs at once; a single device named exactly, udev, launchd and scripts without a terminal are not asked.
- `--pick` (`status`, `start`, `stop`, `restart`, `down`) opens fzf at once with the devices of the selection (all of them without one): `TAB` marks several, Enter picks them, Esc cancels the command; the question follows as without `--pick`. It needs fzf and a terminal: without them (or with `--quiet`, `--json`) the command fails and runs for no device. `logs`, `shell` and `exec` take `--pick` in the place of the device (`zebrunner-farm exec --pick connector adb devices`); `logs` and `shell` without a device pick it with fzf at a terminal.
- On macOS a group of the iOS devices (all the devices or `ios`) unloads the devices listener for `stop`, `down` and `restart` and loads it after `start` and `restart`; once a USB iOS device (the ones of the listener) is dropped from the group, with `-x` or at the question (`f`, `x`, `p`) or with `--pick`, the listener stays as it is: it keeps working for that device (e.g. `zebrunner-farm stop -x iPhone_15` keeps `iPhone_15` handled on a reconnect).
- Every device has a title (its name, platform, connection and udid; the counter `2/7` in a group) and one line per container: the action and the full name of the container, `running` (kept), `started`, `created <id>`, `stopped`, `removed`, `no container` or `NOT created <container>: <the error of docker>` with the fix under it; the containers after a failed one are not created. A group starts with its title and ends with a summary: the devices that succeeded, were skipped (a USB device of Linux that is not plugged in) and failed, the time, the failed devices and the command to retry them. At a terminal a spinner shows the container docker works on (not with `-q`); without a terminal (udev, systemd, launchd, a pipe) the output is plain text without colors, a line per container: `journalctl -u 'mcloud-device-*' | grep 'NOT created'`.
- The status of `start`, `stop`, `restart` and `down` is `0` when every device succeeded (a skipped one too), `1` when a device failed (a container not created, started, stopped or removed; the lock of the device not taken; an invalid device): the unit of udev of the device is failed then (`systemctl --failed`), the others go on. `2` is a wrong use (an unknown command, role or option of `logs`, `shell`, `exec`, `completion`).
- `status` of a group is a table, a row per device: the mark of each container (`C S A U`: connector, STF, appium, uploader), the uptime of appium (or of its oldest running container) and the restarts with the containers that have them, or the first container that exited; a USB device that is not plugged in is `disconnected`. The marks are green (running), amber (starting, unhealthy, restarting), red (exited, dead) and muted (no container) dots at a terminal with colors, the letters `R`, `S`, `X` and `-` without colors. `status <device>` (or `-v` for every device of a group) shows its containers: state, health, uptime and the full name, a warning with `docker logs --tail 50 <container>` for a container that restarted or is unhealthy, a failure for one that exited. `--watch [seconds]` shows it again every 5 seconds (or the seconds) at a terminal until Ctrl-C. The status of `status` is `0` (`1` for an invalid device).
- `status --json` prints the devices and their containers as a JSON array for the monitoring, the messages go to stderr: per device `id`, `name`, `os`, `connection`, `location`, `plugged_in` (a USB device: `true` or `false`, `null` of the other connections) and `containers` (`connector`, `stf`, `appium`, `uploader`): `exists`, and of an existing one `status` (docker: `running`, `exited`, ...), `health` (`healthy`, `unhealthy`, `starting`, `null` without a health check), `started_at`, `uptime_seconds` (of a running one) and `restarts`, e.g. `zebrunner-farm status --json android | jq -r '.[] | select(.containers.stf.health != "healthy") | .name'`.
- `doctor` is `./zebrunner.sh doctor` of the agent folder from any folder (see [Doctor](#doctor)); `doctor usb-stats [devices] [--days <n>] [--threshold <n>] [--json]` (Linux) the stability of the USB ports and whether the port or the device is to blame, see [USB stability](#usb-stability); `doctor usb-map [devices] [--days <n>] [--json]` (Linux) which device is in which port of which hub and the free ports, see [USB map](#usb-map).
- `logs <device> [role] [-f|--follow] [--tail <n>]` is `docker logs` of a container of one device (its name or udid; the last 200 lines by default), `shell <device> [role]` a shell in it (bash, or sh without it), `exec <device> <role> <command...>` runs a command in it (`docker exec -it` when both its input and its output are a terminal, else `docker exec -i`: a redirected or piped output stays byte for byte, e.g. `adb exec-out screencap -p > shot.png`); the roles are `connector`, `stf`, `appium` (the default of `logs` and `shell`) and `uploader`, e.g. `zebrunner-farm logs Pixel_7 stf -f`, `zebrunner-farm exec Pixel_7 connector adb devices`.
- The completion of the commands, the options, the devices, the groups and the roles in bash and zsh: `eval "$(zebrunner-farm completion bash)"` in `~/.bashrc` (`zsh` and `~/.zshrc` for zsh); it is `patch/completion.sh` of the agent, which asks `zebrunner-farm __complete` for the candidates: it reads the devices list only, runs no docker and changes nothing.
- `stop`, `restart` and `down` stop the containers of a device one by one and wait for them: appium first (up to 40 s: it finishes the recordings of the active sessions), then the uploader (up to 130 s: it uploads them, its `FINISH_TIMEOUT` is 120 s), STF (30 s) and the connector (10 s); `restart` and `down` remove a container after its stop and the volume of the logs after all of them. The stop of a device with the recordings to upload takes a few minutes, the macOS devices listener waits for its actions up to 30 minutes as the units of udev of Linux.

### USB stability

A device that loses its USB connection again and again (a worn cable, a worn port of a hub, a broken connector of the device) looks like many other failures: its containers come and go, STF and the battery level are stale, the sessions break. `zebrunner-farm doctor usb-stats [devices] [--days <n>] [--threshold <n>] [--json]` (Linux) reads the kernel log (`journalctl -k`, all the boots of the period of a persistent journal) and the docker log and reports every port with a disconnection:

```text
USB stability, 7 days (2026-11-11 .. 2026-11-18), threshold 10 disconnects/day

PORT         DEVICE                                 DISC  MAX/DAY  ERRORS  NOT_A_NODE  VERDICT
1-6.4.2      iPhone_15_Pro_Max (S3_A1)               517      188       3         214  port: different devices flapped here: Samsung_Note_10 (S3_A2), iPhone_15_Pro_Max (S3_A1)
1-13.4.2     Samsung_Note_10 (S3_A2)                   1        1       0           0  ok

Ports held by more than one device in the period:
1-6.4.2      Samsung_Note_10 (S3_A2) until 2026-11-07, iPhone_15_Pro_Max (S3_A1) since 2026-11-07
1-13.4.2     iPhone_15_Pro_Max (S3_A1) until 2026-11-07, Samsung_Note_10 (S3_A2) since 2026-11-07
```

- `DISC` the disconnections of the port, `MAX/DAY` the most of a day, `ERRORS` the errors of the USB protocol (`-71`, `-110`, `-32`, `-62`), `NOT_A_NODE` the failed starts of the containers of its device (`not a device node` of the docker log: the device was gone again); the device is the last one of the port (by its serial: the adb serial of Android, the UDID of iOS without its dash), an unknown device is one that is not in the devices list.
- A port flaps when it has more than `--threshold` (10) disconnections on a day: a reboot of a device, the switch of the USB mode of an iPhone or a plug by hand are 1-2 a day. The verdict of a flapping port: `port` when different devices flapped on it or its device is stable on another port (replace the cable or use another port), `device` when the device flaps on other ports too or another device was stable on the port (check the connector and the cable of the device), `unknown` for one device on one port all the period (swap it with a stable device of another port, then run it again).
- `[devices]` (names, udids, groups, patterns, `-x`): the ports these devices were on; all the ports with a disconnection without them. `--days` is the period (7 by default), `--json` the report for the monitoring (per port the days, the devices it held, the verdict). The status is `1` with a flapping port, `2` when the logs are not readable: the groups `adm` or `systemd-journal` read them (or `sudo`).
- A volatile journal has the current boot only: the report says when the kernel log starts. `./zebrunner.sh doctor` warns about the flapping ports of the last 7 days (see [Doctor](#doctor)).

### USB map

When devices or cables are swapped at the site, the first question is which device is in which port of which hub and which ports are free. `zebrunner-farm doctor usb-map [devices] [--days <n>] [--json]` (Linux) shows the USB tree of the host from sysfs (no journal needed, the state of now):

```text
build-01: 1 hubs (+1 built in), 5 of 10 ports used, 0 farm devices not on USB

1-13, 4 ports, built in, 05e3:0608, 0000:00:14.0 Intel Corporation Raptor Lake USB 3.2 Gen 2x2 (20 Gb/s) XHCI Host Controller (rev 11)
   1 1-13.1             -- empty --
   ...

3-2 (USB3 4-2), 10 ports, 2109:2813+2109:2813+2109:2813, 0000:02:00.0 Renesas Technology Corp. uPD720201 USB 3.0 Host Controller (rev 03)
   1 3-2.1              -- empty --
   2 3-2.2        480M  iPhone_15 (S1_E1)                        00008120-0010A1B2C3D4E5F6
   3 3-2.3.1            -- empty --
   ...
   7 3-2.4.1      480M  Samsung_Galaxy_S24 (S1_A1)               R3CX00000AA

Host ports, 0000:00:14.0 Intel Corporation Raptor Lake USB 3.2 Gen 2x2 (20 Gb/s) XHCI Host Controller (rev 11)
     1-8          480M  iPhone_15_Pro                            00008120-0010B2C3D4E5F6A7
     1-12         12M   unknown MYSTIC LIGHT                     A0000000001

Free ports: 3-2.1 3-2.3.1 3-2.3.2 3-2.3.3 3-2.3.4
Not on USB: Samsung_Galaxy_S22 R5CW000000B (last seen 2026-11-25 05:03:19 on 1-7.3)
```

- Every physical hub with its ports, the whole tree: a hub behind a hub is a hub of its own (`on port 2 of 1-11`). A multi-port hub is several hub chips inside: a hub chip on the last ports of another one (`43f2:1211` -> `43f2:1211` -> `0bda:5411` of a common 10-port hub, the ports `x.1 x.2 x.3 x.4.1 x.4.2 x.4.3 x.4.4.1 .. x.4.4.4`) is shown as one hub with the ports 1-10, its chips in its title; a hub that the kernel tells removable, or a USB2 hub on a USB3 hub, is a hub plugged in. The USB3 half of a hub (the `peer` of its ports in sysfs) is a part of the hub, a USB3 device is on the port of the hub with its USB3 path.
- Per hub its controller (the PCI address and the name of `lspci`: the chipset or a PCIe card) and whether it is built in (a hub of the board, its ports are not counted as free). Per port its number on the hub, its path, the speed and the device of the farm (its name, location and id, by the serial: the adb serial of Android, the UDID of iOS without its dash), an unknown USB device or `-- empty --`. The devices on the ports of the board are the host ports.
- At the end the free ports and the USB devices of the farm (`connection: usb`) that are not on USB (unplugged, a dead battery, a cable without data lines), with the port and the time the kernel log (all of it) last saw them.
- `[devices]` (names, udids, groups, patterns, `-x`): the hubs of these devices only. `--days <n>` adds the disconnects of every port in the days (`disc7d=250`, the kernel log as `usb-stats`), so a flapping port stands out; `--json` is the tree for the monitoring. The status is `1` when a device of the farm (of the devices) is not on USB, `2` without sysfs. `./zebrunner.sh doctor` warns about the devices of the farm that are not on USB.
- The order of the ports of a hub is the one of the kernel, not always the one of its case: label the ports of a hub once by plugging one device into each of them while `journalctl -k -f` (or `zebrunner-farm doctor usb-map` again) shows its path.

### MDM

The MDM of the devices of MCloud ([mcloud-mdm](https://github.com/zebrunner/mcloud-mdm), `MDM_ENABLED=true` of mcloud, see [MDM of mcloud](https://github.com/zebrunner/mcloud#mdm)): the agent of mcloud-mdm as the device owner of an Android device (no factory reset), the enrollment profile of a supervised iOS device. The host reaches it with the settings of `./zebrunner.sh join` (`MCLOUD_URL`, `MCLOUD_TLS_PIN`, `MCLOUD_NODE_TOKEN`): MCloud checks the node token and lets its own MDM in, the host needs no setting of its own for Android. The public address of the site must be in `MDM_SITE_ADDRESSES` of mcloud.

`./zebrunner.sh mdm <status|enroll|release|supervise> [devices...] [-x <devices>] [-q|--yes] [--uninstall] [--force]` prepares the devices for the farm (`zebrunner-farm` keeps the work of the running devices). The devices are selected as by `zebrunner-farm` (udids, names, groups such as `ios` or `android`, patterns in quotes, `-x` to skip some; `status` without devices: all of them), shown at a terminal before a change, then handled one by one, each with the lock of zebrunner-farm:

- `status` asks the MDM only, the device is not touched: Android `known`, `device_owner`, `last_sync_at`, `agent_version`, `managed`, `presets`; iOS `known`, `enrolled`, `last_seen_at`, `product`, `os_version`.
- `enroll` stops the containers of the device (a new device without containers is enrolled too), runs a one-shot container of the image of its connector with its USB device (Linux) or with the adb server and usbmuxd of the host (macOS), then starts the containers that ran again:
  - Android: the agent of the MDM installed, the device owner set (Android refuses it while the device has an account, e.g. Google, or a second user: remove them first), the agent set up with the answer of the MDM; the adb key of the farm (`mcloud-key-volume`), no new prompt on the device;
  - iOS: the enrollment profile of the MDM installed with the supervision identity of the farm, `MDM_SUPERVISION_P12` (a PKCS#12 file of the host) and `MDM_SUPERVISION_P12_PASSWORD` of `config/settings.yml`, without a prompt; the device must be supervised by that identity (`supervise`). A lost pairing is made again with the identity, the pairing records of the device stay in its volume `<device>-lockdown`.
- `supervise` (iOS) **erases** the device and prepares it without a person at the device: Activation Lock (Find My) and a passcode are checked first (the device is not erased then), the erase, the activation, the supervision with the identity of the farm (`MDM_SUPERVISION_ORG`, every Setup Assistant pane skipped), Developer Mode, the Wi-Fi of the farm (`MDM_WIFI_SSID`, `MDM_WIFI_PASSWORD`, `MDM_WIFI_ENCRYPTION`: the MDM reaches the device over it), the enrollment; the containers of the device are created again (the device comes back on USB with another number), the connector installs WebDriverAgent again and continues the Setup Assistant (it shows "iPhone Partially Set Up" after the restart of Developer Mode: WebDriverAgent swipes Hello up and touches "Continue with Partial Setup" until `SetupDone` of the device) and checks that an app starts. A device supervised already is only enrolled (`--force` erases it anyway). It asks for the word `erase` at a terminal, `--yes` without one. On Linux the one-shot container gets the USB bus of the device (the device restarts on it with another number): the other iPhones of the bus stop meanwhile (their locks are held), their containers start again at the end. About 10 minutes a device; checked with iOS 18.3 and 26.2.1 on Linux.
- `release`: Android, the agent gives up the device owner (the restrictions of the MDM go away, no factory reset), `--uninstall` removes the agent too; iOS, the MDM removes its enrollment profile over APNs (the device leaves the MDM with every profile of it once it is online, it stays supervised).

Each call names its device (the udid, the adb serial). MCloud with `MDM_ENFORCE_NODE_BINDING=true` acts only on the devices STF binds to this node: another device is refused ("STF binds it to another node or does not know it yet"; a new device registers in STF once its containers run).

The node token, the setup of the agent and the passwords of the identity and of the Wi-Fi go to curl and to the one-shot containers on their stdin or in a folder of the process (`700`), never in the arguments of a process. adb alone cannot remove the agent of a device (it is no test-only app): the test users of the remote debug cannot release a device.

## Usage

### Android devices

- Enable the Developer Option and USB Debugging for each Android device.
- Connect an Android device physically to a USB direct port or through the hub.
- For the 1st connection, trust the device by picking "always trust..." on the device.

#### Reboot of an Android device

A device that has not been rebooted for long, with many installs and uninstalls of apps, runs out of the app UIDs of its PackageManager: no app can be installed (STF: `STFService.apk could not be installed [INSTALL_FAILED_INSUFFICIENT_STORAGE: ... could not be assigned a valid UID]` while the storage is free, its container spends its restarts) and only a reboot of the device helps. `allow_reboot: true` of the device in `config/devices.yml` (or `config/mac-devices.yml`) lets its connector reboot it (`ALLOW_REBOOT` of [mcloud-android-connector](https://github.com/zebrunner/mcloud-android-connector#reboot)), at most once per 6 hours; the same failure after its reboot is left to a person. Without it the connector log recommends the reboot. A change needs `./zebrunner.sh ansible` and `zebrunner-farm restart <device>`.

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

   The fork also builds it from the command line, without the steps 2-8: `bash Scripts/zebrunner-build.sh --help` (`--sdk device` for the devices, `--sdk sim` for the simulators, signed with `--code-sign yes --team-id <team>`). The installable `.ipa` of a device build comes with [zebrunner/WebDriverAgent#17](https://github.com/zebrunner/WebDriverAgent/pull/17); an earlier device build is a `.zip` of the `.app`: put it into `Payload/` as in the steps 6-8.

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
11. The bundle id is `com.facebook.WebDriverAgentRunner.xctrunner` (`WDA_BUNDLEID` by default): Xcode appends `.xctrunner` to the bundle id of the runner, so a build with another one (`--bundle-id <id>` of `Scripts/zebrunner-build.sh`, `PRODUCT_BUNDLE_IDENTIFIER`) needs `WDA_BUNDLEID: <id>.xctrunner` (or `wda_bundleid` of the device).
12. The iOS simulators of macOS take the unsigned simulator build (`WDA_SIMULATOR_FILE` or `wda_file` of the device, a `.app` folder or its `.zip`): `WebDriverAgentRunner-Build-Sim-arm64.zip` of the [appium/WebDriverAgent releases](https://github.com/appium/WebDriverAgent/releases) (upstream, without the changes of the fork) or `bash Scripts/zebrunner-build.sh --sdk sim` of the fork.

#### Developer Disk Images

The connector mounts the Developer Disk Image of the iOS version of the device before WebDriverAgent starts. The deploy of a host with iOS devices (`./zebrunner.sh ansible`, the `download` role) clones the images of Xcode of [zebrunner/DeveloperDiskImage](https://github.com/zebrunner/DeveloperDiskImage) (shallow and sparse: the images the connector mounts only, without the Cryptex ones; about 0.5 GB per host) and updates them on every deploy; `zebrunner-farm` mounts the folder read-only into the connectors of the iOS devices but the simulators (`/opt/zebrunner/ddi`, `DDI_DIR` of [mcloud-ios-connector](https://github.com/zebrunner/mcloud-ios-connector#readme)). Without the folder, or without the image of the device in it, the connector downloads the image with go-ios as before (`ios image auto`, the internet).

| Setting | Default | What it is |
| --- | --- | --- |
| `DDI_ENABLED` | `true` | `false`: no clone and no mount, the connector downloads the images |
| `DDI_REPO` | `https://github.com/zebrunner/DeveloperDiskImage.git` | the repository of the images, e.g. a mirror of the network of the host |
| `DDI_VERSION` | `main` | its branch or tag |
| `DDI_DIR` | `DeveloperDiskImages` of the agent folder (out of git) | the folder of the clone, an absolute path of its own: every deploy resets it to `DDI_VERSION` |

- A host with Android devices only clones nothing. A failed clone or update (no access to the repository) is reported (`The Developer Disk Images ... are not updated`) and does not stop the deploy: the connectors mount the earlier clone or download the images.
- A new folder is mounted into the connectors created after it: `zebrunner-farm restart ios` recreates them.
- Do not change the clone: the next deploy drops a local change of it.

#### Reboot of an iOS device

Sometimes testmanagerd of an iPhone stops answering (often after a mass restart of the containers): WebDriverAgent hangs at `loading Accessibility`, the connector restarts until `RESTARTS_LIMIT` and only a reboot of the device helps. `allow_reboot: true` of the device in `config/devices.yml` (or `config/mac-devices.yml`; iOS with the `usb` or `wireless` connection) lets its connector reboot it (`ALLOW_REBOOT` of [mcloud-ios-connector](https://github.com/zebrunner/mcloud-ios-connector#wda-cant-start-reboot)): after 3 starts in a row with this failure, at most once per 6 hours; a device that fails again after its reboot is left to a person, and an iOS 17+ device with a passcode is rebooted only when the connector keeps a backup of its pair record. Without it the connector log recommends the reboot. A change needs `./zebrunner.sh ansible` and `zebrunner-farm restart <device>`.

### SmartTestFarm

- Open in your browser `http://<PUBLIC_IP>/stf`, authenticate yourself based on preconfigured auth system.
- The connected device should be available in STF.
- Disconnect the device from the server. Device containers will be removed asap, then, in 15-30 sec, the device should change the state in STF to disconnected as well.
- Use different commands from `zebrunner-farm start/stop/restart/down/status` to manage all devices, a device by udid or name, or all devices of a platform (ios/android).
  > Run `zebrunner-farm help` to see available commands and options, see [Devices management](#devices-management).

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `./zebrunner.sh ansible` fails on `Pull Zebrunner images` and `Check that images failed to pull exist locally` with `denied: Your authorization token has expired` or `403 Forbidden` | an expired login to public.ecr.aws in `~/.docker/config.json` of the user who runs the deploy (it pulls as this user, not as root): the images are public, `docker logout public.ecr.aws` (or log in again) |
| Linux: `./zebrunner.sh ansible` fails on `Pull Zebrunner images` with `permission denied while trying to connect to the Docker daemon socket` | the user is not in the `docker` group: `sudo usermod -aG docker $USER`, log in again |
| the pull fails with `manifest unknown` | the tag of `versions.yml` (or of `config/settings.yml`) is not published, see the images of the current [mcloud](https://github.com/zebrunner/mcloud) |
| Linux: the deploy passed, the devices plugged in before it have no containers | udev starts them on the next connection only: `zebrunner-farm start` |
| `./zebrunner.sh join` stops with `the TLS key of the server is not the pinned one` | the join string is of another MCloud (or the address of the join string leads elsewhere), or a man in the middle; a new TLS key of MCloud needs a new join string |
| `./zebrunner.sh join` stops with `MCloud refused the enrollment (HTTP 403)` | the invite is used, expired, replaced by a newer one of the label, or of another label: a new `./zebrunner.sh node-invite` on the MCloud server |
| `zebrunner-farm start` fails with `cannot assign requested address` (Linux) or `bind ... can't assign` (macOS) | the [WireGuard tunnel](#wireguard-tunnel) is on and its interface is down: `./zebrunner.sh doctor`; once it is up `zebrunner-farm start` (Linux: `mcloud-wireguard-up` does it after `wg-quick@mcloud-node`, `journalctl -u mcloud-wireguard-up`) |
| the containers are healthy, the devices are not in STF | `./zebrunner.sh doctor`: MCloud does not know or revoked this host (a new invite and `./zebrunner.sh join`), its address in MCloud is not `STF_PROVIDER_HOST`, the devices are not bound to it (the containers created before `join`: `./zebrunner.sh ansible`, `zebrunner-farm restart`); the STF triproxies log `Refused the ZeroMQ client ... with the unknown key` for a key MCloud does not know, see [ZeroMQ security](#zeromq-security) |
| the devices are in STF, not in the grid; Appium logs `An attempt to register with the grid <hub URL> was unsuccessful` | the reason is in the log of Appium (`device-<name>-<udid>-appium`) or of `mcloud-grid`: `is not reachable from the hub` - `STF_PROVIDER_HOST` and `appium_port` are not reachable from the MCloud server (in its network the address of this host there, see [Device hosts in a private network](#device-hosts-in-a-private-network)); an unknown or revoked node token, or a node url whose host is not the address of the invite - `./zebrunner.sh doctor`, see [Grid registration](#grid-registration) |
| the screenshots or the app installs of the devices fail | MCloud refuses the token of this host (`./zebrunner.sh doctor`), or `PUBLIC_IP` is not reachable from this host (e.g. the public address of a server of the same network behind a NAT without hairpin: resolve it to its address in the network) |
| no video of the sessions, the devices have no `-uploader` container | no `S3_BUCKET` in `config/settings.yml`: appium records no video and the devices get no uploader, see [Recordings](#recordings) |
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
  # the same by the name or the udid of the device (appium by default):
  zebrunner-farm status <Name>
  zebrunner-farm logs <Name> connector -f
  ```

- If you have any problems running ansible:
  - Make sure you have sudo access and try to run ansible with sudo permissions.
  - Try to run ansible commands manually: `agent.yml` deploys the role of the OS of the host (`devices` of Linux, `mac-devices` of macOS); `devices.yml` and `mac-devices.yml` of the earlier commands import it

  > To download the required components and register the devices:

  ```bash
  ansible-playbook -vvv --ask-become-pass -i hosts agent.yml
  ```

  > To deploy without the download of the images (the role of the OS only):

  ```bash
  ansible-playbook -vvv --ask-become-pass -i hosts agent.yml --tag registerDevices
  ```

  Ubuntu 25.10+ has sudo-rs as `sudo`: ansible does not recognize its password prompt and stops with "Timed out waiting for become success or become password prompt". `./zebrunner.sh ansible` uses `sudo.ws` (the original sudo, `sudo apt install sudo`) then, add `--extra-vars ansible_become_exe=sudo.ws` to the commands above.

  > To run it non-interactively, keep the sudo password in an ansible-vault encrypted file instead of the command line (use `--vault-password-file` instead of `--ask-vault-pass` for automation):

  ```bash
  ansible-vault create become.yml    # with the line: ansible_become_password: PSWD
  ansible-playbook -vvv -i hosts --extra-vars @become.yml --ask-vault-pass agent.yml
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

- The roles: `devices` (Linux) and `mac-devices` (macOS) deploy the agent of the OS; `common`, their dependency (`meta/main.yml`), has the values by default and the checks of the settings and the devices shared by both (`roles/common/tasks/checks.yml`, imported after the check of the OS; the checks of the devices of both OS are `roles/common/files/devices.py`, run by the deploy with the python of ansible and by `./zebrunner.sh doctor`), and `zebrunner-farm` (`roles/common/tasks/farm.yml`): one static script of both OS (`roles/common/files/zebrunner-farm`, the branches of `FARM_OS`) with its settings rendered into an env file (`roles/common/templates/zebrunner-farm.env`); the tests run it with `ZEBRUNNER_FARM_ENV`; `download` pulls the images and clones the Developer Disk Images of the iOS devices (also with `common` as its dependency).
- With `JUNIT_DIR` set, `tests/lint.sh` and every test write JUnit XML into it. CI publishes the results as annotations and a job summary, and keeps the XML files as artifacts.
- CI runs the tests on Linux and macOS on every push; a pull request runs them on macOS only when it changes a file the macOS tests use: all but the docs, the settings of the linters, `roles/devices` and `tests/Dockerfile` (the list of the job `changes` of `.github/workflows/ci.yml`).
- The `usbmuxd_watch` binary of the `mac-devices` role is built from `roles/mac-devices/files/usbmuxd_watch.c` and the pinned release tarballs (sha256) of libplist, libimobiledevice-glue and libusbmuxd. After a change of the source or of a library version, rebuild it on macOS with the Xcode command line tools and commit it. CI builds it the same way in its macOS tests job and runs `tests/usbmuxd_watch_test.sh` on the result too; it does not compare the result with the committed binary, which another Xcode builds differently:

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
