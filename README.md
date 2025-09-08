# Maintainerr Overlay Helperr

**Project inspired by [Maintainerr Poster Overlay](https://gitlab.com/jakeC207/maintainerr-poster-overlay)**

This project is a helper script that works in combination with [Maintainerr](https://github.com/jorenn92/Maintainerr), adding a Netflix-style "leaving soon" overlay on top of your media. It integrates with Plex and Maintainerr to download posters, add overlay text, and upload the modified posters back to Plex. It runs periodically to ensure posters are updated with the correct information.

### Using Calculated Date
<img width="1144" alt="preview" src="https://github.com/user-attachments/assets/20ea3dd1-fb39-4431-b093-08241a3a4615">

### Using Days Left
<img width="905" height="318" alt="Screenshot 2025-09-05 at 07 37 57" src="https://github.com/user-attachments/assets/5ed6e6fb-a06f-40f3-aaff-fac85b142693" />

### Features

- **Collections**: supports all collection types, can process multiple collections & can reorder Plex collection in either ascending or descending order depending on deletion date
- **Customizable overlay**: use custom text, color, size and shape of the overlay
- **Overlay reset & deletion**: revert back to the original poster & delete the generated overlay poster from Plex metadata folder
- **Automatic poster update**: change the deletion date in the overlay automatically when making changes to the Maintainerr rule(s)
- **Display days left vs exact date**: choose between showing the calulcated date of removal or days leading up to it

### Requirements

- Docker
- Plex Media Server
- Maintainerr

### Usage

#### Docker
1. Build and Run the Container

Create a **docker-compose.yml** file with the following content:
```yaml
version: '3.8'

services:
  maintainerr-overlay-helperr:
    image: gsariev/maintainerr-overlay-helperr:latest
    environment:
      PLEX_URL: "http://192.168.0.139:32400"
      PLEX_TOKEN: "PLEX TOKEN"
      MAINTAINERR_URL: "http://192.168.0.139:6246"
      IMAGE_SAVE_PATH: "/images"
      ORIGINAL_IMAGE_PATH: "/images/originals"
      TEMP_IMAGE_PATH: "/images/temp"

      RUN_ON_CREATION: "true" #Enable to run the overlay logic upon booting the container; disable to wait for the CRON run
      REAPPLY_OVERLAY: "false" #Enable to force the re-processing of processed overlays
      RESET_OVERLAY: "false" #Enable to reset all overlays and use the original media posters
      USE_DAYS: "true" #Enable to use days left; disable to use calculated date

      # Change the values here to customize the overlay
      FONT_PATH: "/fonts/AvenirNextLTPro-Bold.ttf"
      FONT_COLOR: "#ffffff"
      BACK_COLOR: "#B20710"
      FONT_SIZE: "3.2"
      PADDING: "1.2"
      BACK_RADIUS: "0"
      HORIZONTAL_OFFSET: ""
      HORIZONTAL_ALIGN: "center"
      VERTICAL_OFFSET: "3"
      VERTICAL_ALIGN: "top"

      DATE_FORMAT: "MMM d"     # Set your desired date format between "d MMM" or "MMM d"
      OVERLAY_TEXT: "Leaving"    # Set your desired text to display before removal date

      #Customize messages for when using days
      TEXT_TODAY: "last chance to watch"
      TEXT_DAY: "gone tomorrow"
      TEXT_DAYS: "Gone in {0} days"

      DATE_FORMAT: "MMM d"    # Set your desired date format between "d MMM" or "MMM d"
      OVERLAY_TEXT: "Leaving"    # Set your desired text to display before removal date
  
      ENABLE_DAY_SUFFIX: true    # Enable or disable date suffix (i.e. th from November 14th). Mainly for french people
      ENABLE_UPPERCASE: false    # Use uppercase or lowercase for date format

      LANGUAGE: "en-US"    # Used for date format and month abbreviation language. You can change this as needed (e.g., "fr-FR" for French), will default to en-US if not provided.

      CRON_SCHEDULE: "0 */8 * * *" #Configure the schedule CRON should execute the script; default is          every 8 hours
      RUN_ON_CREATION: "false" #Set to true if you want the script to execute once on initial boot; will        use CRON after or set to false to use only CRON

      REAPPLY_OVERLAY: "false" #Will reapply overlays every time the script runs if set to true

      PLEX_COLLECTION_ORDER: "asc" #Choose between ascending (asc) and descending (desc)
      PROCESS_COLLECTIONS: "Leaving Soon" #Name of the colletion to be reodered. You can specify  multiple seperated by , "Leaving Soon, Not Watched, Bad Movies"
      
    volumes:
      - /mnt/user/appdata/maintainerr/images:/images
      - /mnt/user/appdata/maintainerr/fonts:/fonts
      - /mnt/user/appdata/Plex-Media-Server/Library/Application Support/Plex Media Server/Metadata:/plexmeta #path to plex metadata folder
      - /mnt/user/appdata/Plex-Media-Server/Library/Application Support/Plex Media Server/Plug-in Support/Databases:/plex-db #path to plex database folder

```
2. Run the container
```yaml
docker-compose up --build
```

#### Unraid
Maintainerr-Overlay-Helperr community app available thanks to [nwithan8](https://github.com/nwithan8/unraid_templates)

#### Ensure Directories Exist

- Ensure the directories specified in IMAGE_SAVE_PATH, ORIGINAL_IMAGE_PATH, and TEMP_IMAGE_PATH exist on your system.
- Ensure that the font file you are going to use is present in the mapped 'fonts' folder prior to running the script.
- The script will automatically run every RUN_INTERVAL minutes. If the interval is not specified, it defaults to 8 hours.

