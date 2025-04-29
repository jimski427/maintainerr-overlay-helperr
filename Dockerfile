# Use the official PowerShell image
FROM mcr.microsoft.com/powershell:latest

# Install necessary packages
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    libgdiplus \
    libc6-dev \
    imagemagick \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Create symlink for magick
RUN ln -s /usr/bin/convert /usr/bin/magick

# Copy the PowerShell script and fonts into the container
COPY maintainerr_days_left.ps1 /maintainerr_days_left.ps1
COPY AvenirNextLTPro-Bold.ttf /fonts/AvenirNextLTPro-Bold.ttf

# Set the working directory
WORKDIR /

# Run the PowerShell script
CMD ["pwsh", "/maintainerr_days_left.ps1"]
