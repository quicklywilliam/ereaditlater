# The eReader Project

<p align="center">
  <img src="https://github.com/user-attachments/assets/b5b5db2b-9357-4625-9b8f-fa9a692a3b7a" alt="drawing" style="width:45%;"/>
  <img src="https://github.com/user-attachments/assets/f0c72004-3f0e-4984-8537-b92983d227ca" alt="drawing" style="width:45%;"/>
</p>

eReader is an open source client application for read it later services. eReader is based on KOReader, so it works with Kobo/Kindle/etc. eReader is designed to be simpler to use than KOReader, with the assumption that most users will use it alongside their device's native experience (ie for reading ebooks). eReader also allows you to access to a fully functioning version of KOReader if you so desire.

eReader is currently in early development and has only been tested on Kobo so far. It's still very much a work in progress.

## Features

Currently support is limited to Instapaper. Support for other services, including Readwise Reader, is planned for the future.

[x] Authenticate with Instapaper account

[x] Browse saved articles

[x] Download articles and images for offline reading

[x] Open and read articles

[x] Favorite, Unfavorite and Archive Articles

[x] Save new articles

[x] Offline request queueing and gracefull offline support

[ ] Improved access to device controls (backlight, rotation lock, etc)

[ ] One-click installation

[ ] Browsing favorites and archive

[ ] Highlighting text

[ ] Tagging

## Setting up for development

In order to run eReader in the emulator, you will need to your own OAUTH client keys. You can obtain these credentials by [applying for Instapaper API access](https://www.instapaper.com/api). This isn't needed when running the release builds, at least on Kobo.

Once you have them, create a `secrets.txt` file in ~/.config/koreader with your Instapaper API credentials:

```
instapaper_ouath_consumer_key = "your_consumer_key"
instapaper_oauth_consumer_secret = "your_consumer_secret"
```

After this, follow the [typical steps](https://github.com/koreader/koreader/blob/master/doc/Building.md) for building and running koreader.

## How to Install

I recommend you use the [KOReader virtual dev](https://github.com/koreader/virdevenv) environment when building for release. For example, to build for kobo:
```
docker run  --platform linux/amd64  -v [Path to eReader directory]:/home/ko/koreader -it koreader/kokobo:latest bash
cd /home/ko/koreader && ./kodev fetch-thirdparty
./kodev release kobo
```
 Once you have a release, you can install it using the "Manual Installation Method" detailed [here](https://github.com/koreader/koreader/wiki/Installation-on-Kobo-devices#manual-installation-method-based-on-kfmon). Note that this will replace any existing installs of KOReader, but eReader contains a fully functioning instance KOReader. If you like, you can use [NickleMenu](https://github.com/pgaskin/NickelMenu) to setup a button to launch both, ie:
 ```
 menu_item : main : eReader : cmd_spawn : quiet : exec /mnt/onboard/.adds/koreader/koreader.sh -eReader
 menu_item : main : KOReader : cmd_spawn : quiet : exec /mnt/onboard/.adds/koreader/koreader.sh
 ```


## Contributing

This plugin is under active development. Get in touch if you'd like to contribute!

## License

GPL-3.0-or-later
