#!/bin/bash
set -e  # Exit immediately if any command fails

# --- Argument Checking ---
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <Xms_in_M> <Xmx_in_M> <repo_path_or_url>"
    echo "Example (GitHub): $0 1000 8000 https://github.com/SlagterJ/geertenjordy-server.git"
    echo "Example (Local Dev): $0 1000 8000 /home/user/my-local-repo"
    exit 1
fi

MEM_MIN="$1"
MEM_MAX="$2"
REPO_SOURCE="$3"
REPO_DIR="git-repo"
CONFIG_DIR="config"
SCRIPT_NAME="update-and-start.sh"
SERVER_PROPERTIES="server.properties"

# --- Repository Setup (Handle Local and Remote Repos) ---
if [ -d "$REPO_SOURCE/.git" ]; then
    echo "Using local Git repository: $REPO_SOURCE"
    rm -rf "$REPO_DIR"
    cp -r "$REPO_SOURCE" "$REPO_DIR"
elif [[ "$REPO_SOURCE" =~ ^https?:// ]]; then
    echo "Using remote Git repository: $REPO_SOURCE"
    if [ ! -d "$REPO_DIR" ]; then
        git clone "$REPO_SOURCE" "$REPO_DIR"
    else
        cd "$REPO_DIR" && git pull && cd ..
    fi
else
    echo "Error: '$REPO_SOURCE' is not a valid Git repository path or URL!"
    exit 1
fi

# --- Load secrets ---
if [ -f "./secrets.sh" ]; then
    source ./secrets.sh
    export $(grep -oP '^\w+' secrets.sh)
fi

# --- Download packwiz-installer-bootstrap.jar if missing ---
if [ ! -f packwiz-installer-bootstrap.jar ]; then
    echo "Downloading packwiz-installer-bootstrap.jar..."
    wget -O packwiz-installer-bootstrap.jar "https://github.com/packwiz/packwiz-installer-bootstrap/releases/latest/download/packwiz-installer-bootstrap.jar"
fi

# --- Update Mods ---
echo "Running packwiz installer..."
java -jar packwiz-installer-bootstrap.jar -g -s server "$REPO_DIR/pack.toml"

# --- Extract Minecraft Version from pack.toml ---
MINECRAFT_VERSION=$(grep -E '^\s*minecraft\s*=' "$REPO_DIR/pack.toml" | head -n1 | cut -d'"' -f2)
if [ -z "$MINECRAFT_VERSION" ]; then
    echo "Error: Could not extract Minecraft version."
    exit 1
fi
echo "Extracted Minecraft version: $MINECRAFT_VERSION"

# --- Update Fabric Server ---
FABRIC_JAR_URL="https://jars.arcadiatech.org/fabric/${MINECRAFT_VERSION}/fabric.jar"
echo "Checking for updates to fabric.jar..."
wget -N -O fabric.jar "$FABRIC_JAR_URL"

# --- Replace Environment Variables in Config Files ---
process_file() {
    local file="$1"
    echo "Processing $file"
    tmp_file=$(mktemp) || { echo "Failed to create temporary file"; exit 1; }

    sed -E -e ':a' -e 's/\$([A-Za-z_][A-Za-z0-9_]*)/\${\1}/g;ta' "$file" | \
    gawk '{
        while (match($0, /\$\{([A-Za-z_][A-Za-z0-9_]*)\}/, arr)) {
            if (arr[1] in ENVIRON) {
                gsub("\\$\\{" arr[1] "\\}", ENVIRON[arr[1]])
            } else {
                gsub("\\$\\{" arr[1] "\\}", "$" arr[1])
            }
        }
        print
    }' > "$tmp_file"

    mv "$tmp_file" "$file"
}

# Process all files in CONFIG_DIR
while IFS= read -r -d '' file; do
    process_file "$file"
done < <(find "$CONFIG_DIR" -type f -print0)

# Process server.properties
if [[ -n "$SERVER_PROPERTIES" && -f "$SERVER_PROPERTIES" ]]; then
    process_file "$SERVER_PROPERTIES"
fi

echo "Environment variable substitution complete."

# --- Start the Server ---
echo "Starting the Fabric server..."
java -Xms"${MEM_MIN}M" -Xmx"${MEM_MAX}M" -jar fabric.jar nogui

