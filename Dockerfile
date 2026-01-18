# Use the official PowerShell image
FROM mcr.microsoft.com/powershell:latest

# Metadata for GitHub Container Registry
LABEL org.opencontainers.image.source="https://github.com/jimski427/maintainerr-overlay-helperr"
LABEL org.opencontainers.image.description="Maintainerr Overlay Helper with skip empty collections feature"
LABEL org.opencontainers.image.licenses="MIT"
LABEL maintainer="jimski427"

# Install necessary packages
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    libgdiplus \
    libc6-dev \
    imagemagick \
    cron \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Create symlink for magick
RUN ln -s /usr/bin/convert /usr/bin/magick

# Create necessary directories
RUN mkdir -p /fonts /images /images/originals /images/temp

# Copy the PowerShell script and fonts into the container
COPY maintainerr_days_left.ps1 /maintainerr_days_left.ps1
COPY AvenirNextLTPro-Bold.ttf /fonts/AvenirNextLTPro-Bold.ttf

# Copy any additional fonts from fonts directory if they exist
COPY fonts/ /fonts/ 2>/dev/null || :

# Copy docker entrypoint if you have one
COPY docker-entrypoint.sh /docker-entrypoint.sh 2>/dev/null || echo '#!/bin/bash\nexec "$@"' > /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh

# Set the working directory
WORKDIR /

# Use entrypoint for better container control
ENTRYPOINT ["/docker-entrypoint.sh"]

# Run the PowerShell script
CMD ["pwsh", "/maintainerr_days_left.ps1"]
