# Intro
The standard Alpine installation ISO doesn't have out-of-the-box support for custom partitioning alongside a software RAID setup. With this script you can quickly and easily setup your machine to have the partitions you want, and directly get an operating software RAID via mdadm.

_* Currently this has been tested only with RAID 0,1, and 10._

# Getting Started
Boot into the Alpine installation ISO and follow the steps below:
### 1. Prepare the network interface of your server
```bash
setup-interfaces -ra && echo 'nameserver 8.8.8.8' > /etc/resolv.conf
```

This will bring your network interface up and (assuming you have DHCP) automatically establish the connection without any user prompts.
Afterward the configuration for the DNS server of the Alpine installer will be replaced with Google's Public DNS servers' IP address.

### 2. Prepare APK
```bash
setup-apkrepos -f && apk add curl
```
The next step is to start Alpine's script to determine the fastest APK repository for your server, automatically. Once done, `curl` will get installed so we can fetch the `setup.sh` script.

### 3. Download the script

```bash
curl -sL https://tinyurl.com/mrbtnytc -o setup.sh && chmod +x setup.sh
```

This URL is the shorter version for the URL of the file in this repo:
`https://raw.githubusercontent.com/xPh03n1x/Alpine.with.RAID.installer/refs/heads/master/setup.sh`

### 4. Customize per your needs
Open the script with a text editor of your choice (`vi setup.sh`?) and modify the variables to match best your desired setup:
- ```ROOT_PASSWORD="";```
  The password for the `root` user you want on the server. If no value is defined the script will prompt you in runtime.
- ```DRIVES="/dev/sda /dev/sdb";```
  List the drive(s) you want to use for the installation
- ```SWRAID=1;```
  Whether you want to use software RAID
- ```SWRAIDLEVEL=1;```
  The software RAID level you would like to use, if `SWRAID` is enabled. This has been tested only with RAID levels 0, 1, and 10.
- ```HOSTNAME="localhost";```
  The hostname you would like to be set on the installed OS.
- ```TIMEZONE="UTC";```
  The timezone you would like to have on the installed OS.
- ```PARTITIONS```
  List the partition map you would like to get on your device(s) in the following format:
  `PART` `mount point` `file system` `partition size`
- `TMP_SIZE`
  If you would like to allocate some of your RAM to `/tmp` you can utilize the `tmpfs` filesystem. If you have no such plans, you can just leave this with an empty value.
- ```EXTRA_PACKAGES```
  A list of packages installed at the start of the script. These packages are installed only in the Alpine installation runtime, they will not be present on your installed OS.
  The default packages listed here are necessary for the script to work properly. Generally, you don't need to touch this.
- ```OS_PACKAGES```
  A list of packages you would like to have in the installed Alpine OS. With the default list you get `nano`, `openssh`, and `chrony` readily available for you once the installation process is completed and you reboot into your installed Alpine OS.


### 5. Run the script
```
./setup.sh
```
Start the script, sit back, and wait for a couple of minutes. The script will do everything for you and as long as everything goes smoothly - you'll be rebooted into a fresh new Alpine OS using the partitions you wanted, and with RAID (if you chose to use it).


## Important note
For convenience purposes the script configures the OpenSSH installation to utilize password authentication.
**It is highly recommended** that you modify the SSH config file:
```
vi /etc/ssh/sshd_config
```
and disable the password authentication for the `root` user:
```
PermitRootLogin without-password
PasswordAuthentication yes
```
Afterwards, you should of course attach your SSH keys, and so on ...

---

# 🫶🏻 Happy installing!
