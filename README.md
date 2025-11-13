# twitch.sh
## Usage: 
```./twitch.sh <streamer_name>```
Throw into crontab to run every minute
```* * * * * $PATH$/twitch.sh sedskeletony```

Four states are possible
* X was not live, and is now live = no flag file, sends notification
* X was live, and is live = flag file exists, does not send notification
* X was live, and is not live = flag file exists, deletes flag file, does not send notification
* X was not live and is not live = does not send notification

> test line, will remove