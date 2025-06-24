#!/bin/bash

# Export all environment variables for cron access
printenv | grep -v "no_proxy" >> /etc/environment
printenv > /etc/default/locale

# Default CRON interval if not set (every 8 hours)
if [ -n "${CRON_SCHEDULE+1}" ]; then
  echo "\$CRON_SCHEDULE is set: $CRON_SCHEDULE"
  FINAL_CRON="$CRON_SCHEDULE"
else
  echo "\$CRON_SCHEDULE is not set. Using default."
  FINAL_CRON="0 */8 * * *"
fi

# Inject CRON job with full env
CRON_CMD="$FINAL_CRON . /etc/environment; pwsh /maintainerr_days_left.ps1 >> /proc/1/fd/1 2>> /proc/1/fd/2"
(crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab -

# Run on container start (once)
if [ "$RUN_ON_CREATION" = true ]; then
  echo "RUN NOW"
  pwsh /maintainerr_days_left.ps1
fi

echo "[ENTRYPOINT] Starting cron in foreground..."
cron -f