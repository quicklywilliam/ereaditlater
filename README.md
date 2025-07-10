# The eReader Project

<p align="center">
  <img src="https://github.com/user-attachments/assets/b5b5db2b-9357-4625-9b8f-fa9a692a3b7a" alt="drawing" style="width:45%;"/>
  <img src="https://github.com/user-attachments/assets/f0c72004-3f0e-4984-8537-b92983d227ca" alt="drawing" style="width:45%;"/>
</p>

eReader is an open source client application for read it later services (currently just Instapaper). eReader is based on KOReader, so it works with Kobo/Kindle/etc. eReader is designed to be simpler to use than KOReader, with the assumption that most users will use it alongside their device's native experience (ie for reading ebooks). eReader also allows you to access to a fully functioning version of KOReader if you so desire.

eReader is currently in early development and has only been tested on Kobo so far. It's still very much a work in progress.

## Installing eReader

Currently, the easiest way to install eReader is on top of an existing KOReader install. If you already have KOReader installed, make sure you are running the latest release before proceeeding. If you do not already have KOReader, follow [these instructions](https://github.com/koreader/koreader/wiki/Installation-on-Kobo-devices) to install it (using either the semi-automated method or manually installing KFMon and KOReader).

Once you have installed it, you can simply check out the eReader code, plug in your device and run this command:
```
./deploy_ereader.sh
```

 This will install eReader into your existing install of KOReader, but KOReader will continue to be fully functional. The deploy script also add a shortcut to launch eReader using [NickleMenu](https://github.com/pgaskin/NickelMenu). If you already have a KOReader shortcut menu item, it will continue to work as before. 

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

## Contributing

This plugin is under active development. Get in touch if you'd like to contribute!

## License

GPL-3.0-or-later
