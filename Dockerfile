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

# Set the working directory
WORKDIR /

# Run the PowerShell script
CMD ["pwsh", "/maintainerr_days_left.ps1"]
