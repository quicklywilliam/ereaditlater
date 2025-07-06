# Eread-it-later

<p align="center">
  <img src="https://github.com/user-attachments/assets/b5b5db2b-9357-4625-9b8f-fa9a692a3b7a" alt="drawing" style="width:45%;"/>
  <img src="https://github.com/user-attachments/assets/f0c72004-3f0e-4984-8537-b92983d227ca" alt="drawing" style="width:45%;"/>
</p>

Eread-it-later is an open source client application for read it later services. Currently this is limited to Instapaper. Eread-it-later is based on KOReader, so it works with Kobo/Kindle/etc.

Eread-it-later is currently in early development and has only been tested on Kobo so far. It's still very much a work in progress. It probably needs a better name at some point, too.

## Features

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

## How to Install

Download the current [release](https://github.com/quicklywilliam/ereaditlater/releases) and install using the "Manual Installation Method" detailed [here](https://github.com/koreader/koreader/wiki/Installation-on-Kobo-devices#manual-installation-method-based-on-kfmon). Note that it is not yet possible to run this project alongside KOReader – installing will replace your current KOReader install, if any.

## Setting up for development

In order to run the app in the emulator, you will need to your own OAUTH client keys. You can obtain these credentials by [applying for Instapaper API access](https://www.instapaper.com/api).

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
