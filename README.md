# arch-linux-luks-tpm-boot

A guide for setting up LUKS boot with a key from TPM in Arch Linux

## Kudos

This README.md, scripts and hooks are heavily based on the [linux-luks-tpm-boot](https://github.com/morbitzer/linux-luks-tpm-boot) repository by morbitzer.

## Highlights

* Only TPM 1.2.
* No Secure Boot (my hardware does not support it).
* Standard [GNU GRUB](https://www.gnu.org/software/grub/index.html) 2.04 boot loader and UEFI + GPT (but it should also work with UEFI + MBR).
* systemd based [initial ramdisk](https://www.gnu.org/software/grub/index.html) (with small adjustments it may still work with standard busybox based initial ramdisk).
* If reading LUKS key from TPM fails, systemd prompts the user for LUKS passphrase on console.

## Introduction

Microsoft’s Bitlocker does a nice job with encrypting the harddisk and decrypting it at boot time without the user even noticing. If something in the boot-process is changed by an attacker, the system won't start up without having received the correct Bitlocker recovery key. This makes it more difficult ([but not impossible](https://events.ccc.de/camp/2007/Fahrplan/attachments/1300-Cryptokey_forensics_A.pdf)) for an attacker to gain access to a system for which he doesn't know the password, even though the system isn't asking for anything during boot time.

All this is achieved with the help of a little chip on the mainboard, the Trusted Platform Module ([TPM](http://www.howtogeek.com/237232/what-is-a-tpm-and-why-does-windows-need-one-for-disk-encryption/)).

In Linux world, [LUKS or barebone dm-crypt](https://wiki.archlinux.org/index.php/Dm-crypt/Encrypting_an_entire_system) is typically used for full disk encryption. Everything that is needed for full disk encryption (apart from /boot) with TPM already exists, but it is not yet well integrated into default system. Upgrade process (boot loader, kernel, initramfs) is still tricky and requires due care not to end up with an unbootable remote server (LUKS password can still be entered on local console, though).

## Few notes on TPM

There are two scenarios how to achieve full disk encryption with TPM:
* Seal your LUKS key with TPM SRK (see below) and PCRs (tpm_sealdata). In this case, the sealed blob file is stored outside of TPM device (USB disk, separate partition, etc.), however the TPM device must be used to decrypt it (tpm_unsealdata) back to a usable LUKS key.
* Store your LUKS key in TPM NVRAM area and seal it with PCRs (tpm_nvdefine and tpm_nvwrite). In this case, the LUKS key is stored inside TPM device. When needed, it can be read from it (tpm_nvread).

'Sealing' actually means binding to a particular state of PCRs. If PCRs change, reading the key from NVRAM is not possible.

Both of above scenarios are feasible and provide similar security unattended boot. See [here](https://security.stackexchange.com/questions/124338/right-way-to-use-the-tpm-for-full-disk-encryption). Adding a password for SRK is not necessary as long as we 'seal' with PCRs.

This guide is about storing the LUKS key in TPM NVRAM and letting TPM give out the LUKS key without any password as long as the integrity of the system is attested.

This is done by:
* Setting an owner password for TPM device (necessary - needed for storing & sealing to NVRAM).
* Storing the LUKS key to TPM NVRAM area without any area password, but sealing it with the current PCR values.
* After reboot, if PCR values are the same as they were when the LUKS key was 'sealed', TPM will give the LUKS key to anybody who asks.
* To be slightly safer, we block the access to the LUKS key in TPM NVRAM after reading it - this is done via NVRAM permissions `OWNERWRITE|READ_STCLEAR` (only owner can write | can be cleared after reading).

This means, we will not need to use:
* Attestation Identity Key (AIK).
* Endorsement Key (EK).
* Storage Root Key (SRK) (we actually set its password to zeros - so called 'well-known-secret').
* NVRAM area password (we use NVRAM, but do not need its password protection).

See [TrouSerS FAQ](http://trousers.sourceforge.net/faq.html#4.4) for more details on the terms.

## Install Arch Linux + GRUB + encrypted system

It is up to you how you want to have your disks setup - read through the Arch Linux Wiki pages on [partitioning](https://wiki.archlinux.org/index.php/Partitioning) and setup your full disk [encryption](https://wiki.archlinux.org/index.php/Dm-crypt/Encrypting_an_entire_system), just make sure you have a separate unencrypted partition for /boot. You can also [convert](https://wiki.archlinux.org/index.php/Dm-crypt/Device_encryption#Encrypt_an_unencrypted_filesystem) unencrypted partition to LUKS.

E.g.
```
Device       Start        End    Sectors   Size Type                                                                    
/dev/sda1     2048       6143       4096     2M BIOS boot          # Spare partition, not used with UEFI & GPT
/dev/sda2     6144    1054719    1048576   512M EFI System         # Spare partition, no UEFI apps used yet                
/dev/sda3  1054720    2103295    1048576   512M Linux filesystem   # /boot (unencrypted)
/dev/sda4  2103296 1953525134 1951421839 930.5G unknown            # Encrypted partition (root fs)
```

Now you should have a working encrypted system, which asks for a LUKS passphrase on console during boot.

Next step is to enable TPM measurements to be performed by GRUB and stored to TPM PCRs 8 and 9. This happens automatically, as long as the `tpm` module is loaded.

```
$ cat /etc/default/grub | grep GRUB_PRELOAD_MODULES
GRUB_PRELOAD_MODULES="part_gpt part_msdos tpm lvm"
```

And re-generate GRUB configuration by:

```
$ sudo grub-mkconfig -o /boot/grub/grub.cfg
```

## Configuring TPM device

You'll have to take ownership of your TPM in case you haven't done so yet. You might be required to clear your TPM before you do this. Unfortunately, there is no defined way of how to do this, it depends on the hardware you are using. You'll probably be able to reset the TPM in your BIOS – for the systems I have seen so far, you can find the TPM settings under `Security` or `Onboard devices`. If not, you might want to look up a guide on how to reset the TPM on your hardware. Also be carefull if you use multiboot with another operating system which might rely on TPM, too.

First, install `trousers` and `tpm-tools` packages - both available in AUR repository.

Afterwards, you can take ownership of the TPM:

```
$ sudo tpm_takeownership -z
```

The `-z` parameter sets the password for Storage Root Key ([SRK](https://technet.microsoft.com/en-us/library/cc753560%28v=ws.11%29.aspx)) to its default value (all 0s) - we will not use SRK at all.

It will ask for Owner password: choose a strong one. You'll need this one only during updates, so you can store it in a password manager. Only be careful with using special characters such as `\`. Since the bash-scripts we are about to use will hand the password as parameter to some commands, this could cause problems.

Now you can reboot to see if everything works. After the reboot, you can check if the measurements exist in corresponding PCRs:

```
$ cat /sys/class/tpm/tpm0/device/pcrs
PCR-00: 73 5E 54 2B 1B 06 4C EA 91 DA 68 E7 33 18 62 CE 4A 5A 0B 1D
PCR-01: 3A 3F 78 0F 11 A4 B4 99 69 FC AA 80 CD 6E 39 57 C3 3B 22 75
PCR-02: 3A 3F 78 0F 11 A4 B4 99 69 FC AA 80 CD 6E 39 57 C3 3B 22 75
PCR-03: 3A 3F 78 0F 11 A4 B4 99 69 FC AA 80 CD 6E 39 57 C3 3B 22 75
PCR-04: B3 B6 C3 4A 7A 83 48 E4 A6 75 11 B8 E6 42 00 0C 10 E7 FF 13
PCR-05: 02 82 AA 3F CA 2D 1B E0 66 AE 8F EC 97 9D 66 2B 42 1D EE 8B
PCR-06: 3A 3F 78 0F 11 A4 B4 99 69 FC AA 80 CD 6E 39 57 C3 3B 22 75
PCR-07: 3A 3F 78 0F 11 A4 B4 99 69 FC AA 80 CD 6E 39 57 C3 3B 22 75
PCR-08: D3 F6 C9 85 14 27 D4 09 F4 77 F9 F4 98 DD C3 5B 3C 7A 84 E4
PCR-09: A3 85 26 69 72 FB C4 72 0D E1 DA 6D 20 5F DC CE 1B C2 7F 83
PCR-10: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
PCR-11: 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00
[..]
```

PCRs 0 - 7 store measurements (hashes) done by UEFI, it should include the measurement for the first stage of GRUB boot loader, too.

PCRs 8 - 9 store [measurements by GRUB](https://www.gnu.org/software/grub/manual/grub/grub.html#Measured-Boot): PCR 8 is for all executed commands, kernel command line, module command line. PCR 9 is for any file read by GRUB.

This is the core of wanted functionality: if any of the measurements in the PCR 0 - 9 changes after reboot, it means something has changed with our system, TPM will not release the LUKS key and boot process will stop - no decryption of the root fs will take place.

## Add a new key file to LUKS

LUKS allows to store multiple keys (or passphrases) and any of them may be used to decrypt the LUKS partition - this is because the partition is actually encrypted with a MasterSecretKey (there is only one), which in turn is encrypted by your LUKS keys  (there may be more of them).

At the moment, you should have at least one LUKS key (passphrase) setup and probably stored in LUKS key slot 0. I assume you also have a backup of LUKS header - if the header gets damaged on the encrypted partition, you will not be able to unlock it. For the purposes of automatic decryption of LUKS partition during boot, we will use a new key.

First, create a key file, e.g. with the help of `urandom`:

```
$ sudo dd bs=1 count=256 if=/dev/urandom of=/etc/tpm-secret/secret_key.bin
```

Make sure it's not readable for users:

```
$ sudo chmod 0700 /etc/tpm-secret/secret_key.bin
```

Then, add the keyfile to LUKS partition (`sda4` in my case):

```
$ sudo cryptsetup luksAddKey /dev/sda4 /etc/tpm-secret/secret_key.bin
```

NOTE: see the end of README.md for some considerations about keeping unprotected LUKS key file in live file system.

## Install necessary scripts

We will store the secret directly in the TPM - in its NVRAM. For inspiration, you may also want to check out a complex tool called [tpm-luks](https://github.com/shpedoikal/tpm-luks).

Download and copy the contents of `/etc` directory of this repository to your computer (do not overwrite the already existing `/etc/tpm-secret/secret_key.bin`!)

First, to make things easier, I've created `/etc/tpm-secret/tpm_storesecret.sh`, a script that puts the contents of your file in NVRAM and seals it to PCRs 0-9 unless the the parameter `--no-seal` is used. Do not forget to make it executable:

```
$ sudo chmod +x /etc/tpm-secret/tpm_storesecret.sh
```

Using the `--no-seal` parameter for `/etc/tpm-secret/tpm_storesecret.sh` will allow to read the NVRAM area without checking the status of PCRs 0-9. This is useful for testing and upgrades - see below.

Note: I have chosen to set the permission of the NVRAM I am creating to OWNERWRITE|READ_STCLEAR. Using READ_STCLEAR will allow us to block reading the secret from NVRAM once we decrypted our harddisk. Depending on your situation, others might suit better. The full list of possibilities is in `man tpm_nvdefine`.

Further, ther is another script `/etc/tpm-secret/tpm_getsecret.sh` that gets the contents out of the NVRAM. This script will only be able to read the secret from NVRAM once, since it afterwards blocks further reads by reading 0 bits from the NVRAM area (see READ_STCLEAR). Again, it's a bit hacky, but it does its job - make it executable again:

```
sudo chmod +x /etc/tpm-secret/tpm_getsecret.sh
```

You can already test if the scripts are working by writing the contents of the LUKS key file to the NVRAM (we are just testing, so you can use the `--no-seal` parameter) and reading it back out again:

```
$ sudo /etc/tpm-secret/tpm_storesecret.sh --no-seal
$ sudo /etc/tpm-secret/tpm_getsecret.sh | hexdump -C
```

And compare it with the output from the key original LUKS key file on your harddisk:

```
$ sudo hexdump -C /etc/tpm-secret/secret_key.bin
```

The hexdump output should be the same. (Hexdump is useful for outputting binary data to terminal.)

## Modifying initial ramdisk

If storing and reading `/etc/secret-tpm/secret_key.bin` works, it is time to modify initramfs to make use of TPM.

Our task is to:
* Have tcsd daemon running in initial userspace.
* Read the LUKS key from TPM NVRAM and store it to a file.

NOTE: these steps are quite Arch Linux specific:
* /etc/crypttab in Debian allows use of a bash script instead of key file. Arch does not support that.
* Arch makes use of own mkinitcpio script to build the initramfs.

First, you may want to read [mkinitcpio](https://wiki.archlinux.org/index.php/Mkinitcpio) to better understand the next steps.

Arch Linux supports two types of early userspace inits: either a traditional one based on busybox or an alternative one based on systemd.

Either may be used, however I chose systemd based initramfs, because it supports unlocking multiple LUKS devices (in future, I expect to add more encrypted disks to my LVM volume group).

The script `/etc/initcpio/install/tpm` is a hook, which is run when initramfs is build. It just adds the necessary binaries, scripts, systemd service unit and configuration to the initramfs.

Then, modify `/etc/mkinitcpio` to make use of the `tpm` hook:

```
$ cat /etc/mkinitcpio | grep tpm
MODULES=(quota_v2 quota_tree tpm tpm_tis)
HOOKS=(base systemd keyboard autodetect sd-vconsole modconf block tpm sd-encrypt sd-lvm2 filesystems fsck)
```

The `MODULES` directive adds tpm and tpm_tis kernel modules to initramfs (needed for my TPM device, yours may be different).

The `HOOKS`:
* systemd enables systemd based initramfs.
* keyboard adds all possible keyboard modules (iven if no keyboard is attached - usefull for head-less servers).
* sd-vconsole enables console (needed in case when `tpm_getsecret.sh` fails and the LUKS passphrase must be typed in console).
* _tpm_ is my extra hook for TPM NVRAM reading.
* sd-encrypt enables auto-unlocking LUKS devices.
* sd-lvm2 enables supports for LVM (I use LVM on LUKS).

> NOTE: If you chose to use busybox based initramfs, you may try `HOOKS=(base udev keyboard autodetect keymap consolefont modconf block tpm encrypt lvm2 filesystems fsck)` instead.

Further, we must tell systemd where to look for LUKS key file. Create a new file:

```
$ cat /etc/crypttab.initramfs
cryptlvm1      UUID=b561874e-ce31-4721-bde7-1f8e7b728846    /secret_key.bin
```

> NOTE: If you chose to use busybox based initramfs, put this to `/etc/crypttab` instead.

Where cryptlvm1 can be any string, UUID is the /dev/disk/by-uuid/UUID of your encrypted partition (`sda4` in my case) and the last parameter is a path to the LUKS key file (within initramfs).

Build a new initramfs, but better make a backup before doing so:

```
$ sudo /boot/initramfs-linux-lts.img /boot/initramfs-linux-lts.img.orig
$ sudo mkinitcpio -P
```

This will re-generate all initial ramdisks you have configured - if you do not want that, modify the command correspondingly.

## The early userspace boot process

This is how it works:
* UEFI will store its measurements to PCR 0 - 7 and run GRUB boot loader.
* GRUB will store its measurements to PCR 8 - 9 and run the `/boot/vmlinuz-linux-lts` kernel with its initial ramdisk from `/boot/initramfs-linux-lts.img`.
* Kernel will start init process - in my case managed by systemd.
* systemd will start various service unit files, including `/usr/lib/systemd/system/sysinit.target.wants/tpm.service`, which will start `tcsd` daemon, read the LUKS key from NVRAM and store it to `/secret_key.bin`.
* Then, systemd will continue - unlock the LUKS partition, activate LVM, mount real root file system, destroy initramfs and hand-over init to the real root.

## Testing

Finally, you are ready to reboot your system. If everything went well, you should not be asked for a password during boot time.

In case something went wrong, systemd should ask you for your LUKS passphrase and then the boot would normally continue.

In case something went even worse, press E in the GRUB boot menu. Then, append `.orig` to the name of the initrd. Now press `F10` to boot. This should allow you to boot up with your original initramfs (which should ask for a passphrase to decrypt the filesystem, just as before).

## Sealing the NVRAM

Now that you rebooted, your PCRs contain the up to date values from your new configuration that reads the LUKS key from NVRAM during boot time. This means that you are now able to seal the NVRAM to the current state. If anything changes during the next boot (UEFI, kernel, initrd, grub-modules, grub-arguments, etc…), TPM will refuse to give out the LUKS key and boot process will stop and ask for a LUKS passphrase.

```
$ sudo /etc/tpm-secret/tpm_storesecret.sh
```

## Checking if it works

If you now reboot again and modify anything in GRUB menu entry, your system shouldn't boot up and will stop with request for a LUKS passphrase.

Just give it a try, press E in the GRUB boot menu. Then edit for example one of the `echo` lines, to output something different. Then press F10 to boot. This should be enough for your TPM to refuse to give out the key!

It works? Perfect, you are ready to go!  Enjoy having to type one password less during boot time! :)

The system still boots up, although it shouldn't? Have a look at the next step…

## Setting the nvLocked bit

On one of my test systems, I had the problem that the secret stored in the NVRAM could be read even when the PCRs it was sealed to had changed. It took me quite a long time to figure out what went wrong: Apparently, the TPM manufacturer didn't set the `nvLocked` bit, which means that reading the NVRAM was always possible, no matter if you sealed it to some PCRs or assigned a password to it. Thanks to [this discussion](https://sourceforge.net/p/trousers/mailman/message/32332373/) at the TrouSers mailing list, I was finally able to figure out what to do:

You'll have to define an area the size 0 at position `0xFFFFFFF` in the NVRAM. This will equal setting the nvLocked bit. You can do so with the following command:

```
$ sudo tpm_nvdefine -i 0xFFFFFFFF –size=0
```

This solved the problem for some. Afterwards, the sealed NVRAM areas couldn't be read anymore if the PCRs it was sealed to had changed, and the system was finally safe again. As Ken Goldman correctly pointed out:

> If your production platform is delivered that way, I consider that a security bug.

Thanks a lot to Frank Grötzner and Ken Goldman!

## Booting if something went wrong (or if there was a kernel update)

As described earlier, in case something went wrong within this process, or if there was a kernel update and your system won't read the contents of the NVRAM because the kernel-checksum has changed, press E in the GRUB boot menu. Then, append an ".orig" on the line were the initrd is specified. Now press F10 to boot. This allows you to boot the “normal” way, by providing a LUKS passphrase.

NOTE: This is why I recommend not to remove the passphrase from your LUKS partition!

## Kernel update

After kernel, initramfs, GRUB, etc. update, you can run `$ sudo /etc/tpm-secret/tpm_storesecret.sh --no-seal` so that the LUKS key in the NVRAM is not sealed to the PCRs anymore. After you have done this, you should be able to reboot and TPM would give out the LUKS key during initramfs init, just as before the update.

Once you did this reboot, the PCRs will contain the correct values from your new kernel (initramfs, etc.). Now you can run `$ sudo /etc/tpm-secret/tpm_storesecret.sh` one more time, nevertheless without the `--no-seal` parameter, and LUKS key will again get sealed to current PCR values.

## Other considerations

### Encrypted /boot

GRUB 2.04 can deal with encrypted /boot (`cryptomount` - i.e. the first stage of boot loader is not encrypted, the remainder incl. kernel, intramfs, ... is). See [tpm-sealdata-raw-branch of tpm-tools](https://github.com/shpedoikal/tpm-tools) which would provide the `-r (--raw)` option to tpm_sealdata that is needed in order for GRUB to unseal the keyfile at bootloader time.

If you would like to read further on this topic, follow these links:
[issue 5](https://github.com/Sirrix-AG/TrustedGRUB2/issues/), [issue 22] (https://github.com/Sirrix-AG/TrustedGRUB2/issues/22)

### Secure Boot

Another option is a combination with Secure Boot for increased security.

### EFI kernel STUB

It is also possible to avoid GRUB completely and run kernel + initramfs (unencrypted) directly from UEFI (search for EFI kernel STUB).

### Automatic unseal & re-seal of key to PCR

After any change in /boot, it is necessary to unseal the LUKS key from PCRs, reboot and re-seal it again to the new state of PCRs. This is prone to a mistake (the user forgets to unseal and after reboot he has to go to the remote server physically to enter the LUKS passphrase; not such a big deal for a desktop computer, though).

One option would be to block automatic updates to /boot (by setting it read-only, by blocking upgrade of related apps like GRUB, kernel, ... in /etc/pacman.conf) and update these packages only willingly followed by unseal + reboot + re-seal.

Another option would be to pre-calculate the PCR hashes and re-seal with the new values before reboot. I have not found much info if tpm_tools can actually do that and even if so, it would be prone to error any time GRUB changes the measurements methodology.

Yet another option would be to have a pre-shutdown systemd.service to check (cumulative) hash of all files in /boot (and 1st stage of GRUB bootloader) and in case of a change, it would unseal the secret, let the computer reboot and automatically re-seal. Little do I know if it is a good idea, though.

## Last, but not least

**NOTE: If everything has been tested and working properly and the system un-expectedly asks for LUKS passphrase after reboot: think twice as it might mean that your system was compromised.**

**NOTE: systemd sets no timeout on LUKS passphrase entry** (in case `/etc/tpm-secret/tpm_getsecret.sh` fails), **however there is another timeout of 90 seconds for mounting rootfs device - then systemd starts an emergency shell.** If you do not like that, set `rootflags=x-systemd.device-timeout=0` to your GRUB kernel command line.

Some people might not like the idea of the keyfile being stored on the harddisk. Personally, I don't really see a problem with that, since it is stored on an encrypted harddisk. If an attacker is able to read the keyfile from your encrypted harddisk, you are in much bigger trouble anyway. Also, what's the purpose of the whole disk-encryption idea? Stopping an attacker with physical access to your machine from reading your files. So, in case somebody can read your `/etc/tpm-secret/secret_key.bin`, he or she has defeated or by-passed your disk encryption anyway. (And also has root access to your machine...)

Further, if we wipe the `/etc/tpm-secret/secret_key.bin`, we would have to replace the existing key in LUKS key slot with a new one any time we use `/etc/tpm-secret/tpm_storesecret.sh` - both for un-sealing and re-sealing. (However, I might implement this feature in future.)

For all those reasons, I currently don't see a reason for not storing the keyfile on your harddisk.
