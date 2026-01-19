#!/bin/bash

# 🛠️ Check for hostname argument
if [ -z "$1" ]; then
    echo "❌ Usage: $0 <bastion-hostname>"
    exit 1
fi

# 🔐 Check for Environment Variable
if [ -z "$LAB_SSH_PASSWORD" ]; then
    echo "❌ Error: Environment variable LAB_SSH_PASSWORD is not set."
    echo "   Please run: export LAB_SSH_PASSWORD='your-password-here'"
    exit 1
fi

HOSTNAME=$1
PASS=$LAB_SSH_PASSWORD
LOCAL_SECRET="$HOME/Downloads/pull-secret.txt"
LOCAL_SMC="$HOME/Downloads/smcipmitool.tar.gz"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_ALL_YML="$SCRIPT_DIR/../all.yml"
LOCAL_TEMP_SCRIPTS="$HOME/temp-scripts"

echo "📡 Phase 1: Local to $HOSTNAME Transfer..."

# 🔑 1. Copy local public key to bastion 
echo "🔑 Copying your local SSH key to $HOSTNAME..."
sshpass -p "$PASS" ssh-copy-id -o StrictHostKeyChecking=no "root@$HOSTNAME"

# 📜 2. Upload pull-secret.txt
if [ -f "$LOCAL_SECRET" ]; then
    echo "📜 Uploading pull-secret.txt..."
    scp "$LOCAL_SECRET" "root@$HOSTNAME:/root/pull-secret.txt"
else
    echo "⚠️ Warning: $LOCAL_SECRET not found!"
fi

# 🛠️ 3. Upload SMCIPMITool
if [ -f "$LOCAL_SMC" ]; then
    echo "🛠️ Uploading SMCIPMITool binary..."
    scp "$LOCAL_SMC" "root@$HOSTNAME:/root/smcipmitool.tar.gz"
else
    echo "⚠️ Warning: $LOCAL_SMC not found!"
fi

# ⚙️ 4. Upload all.yml configuration
if [ -f "$LOCAL_ALL_YML" ]; then
    echo "⚙️ Uploading all.yml..."
    scp "$LOCAL_ALL_YML" "root@$HOSTNAME:/root/all.yml"
else
    echo "⚠️ Warning: $LOCAL_ALL_YML not found!"
fi

# 📜 5. Upload scripts to remote server
echo "📜 Creating /home/temp-scripts on remote server..."
ssh "root@$HOSTNAME" "mkdir -p /home/temp-scripts"

echo "📜 Uploading project scripts to /home/temp-scripts..."
for script in "$SCRIPT_DIR"/*.sh; do
    script_name=$(basename "$script")
    if [ "$script_name" != "setup-bastion.sh" ] && [ "$script_name" != "jetlag-install.sh" ]; then
        scp "$script" "root@$HOSTNAME:/home/temp-scripts/"
    fi
done

# Upload jetlag-install.sh separately (will be moved later)
if [ -f "$SCRIPT_DIR/jetlag-install.sh" ]; then
    scp "$SCRIPT_DIR/jetlag-install.sh" "root@$HOSTNAME:/root/jetlag-install.sh"
fi

# 📂 6. Upload home temp-scripts
if [ -d "$LOCAL_TEMP_SCRIPTS" ]; then
    echo "📂 Uploading temp-scripts from home directory to /home/temp-scripts..."
    scp "$LOCAL_TEMP_SCRIPTS"/* "root@$HOSTNAME:/home/temp-scripts/"
else
    echo "⚠️ Warning: $LOCAL_TEMP_SCRIPTS not found!"
fi

echo "🖥️ Phase 2: Remote Configuration on $HOSTNAME..."

# 🤖 4. Execute remote setup via SSH
ssh "root@$HOSTNAME" << EOF
    echo "📦 Installing dependencies (tmux, git, python3-pip, sshpass)..."
    dnf install tmux git python3-pip sshpass -y

    echo "📊 Installing k6 load testing tool..."
    if ! command -v k6 &> /dev/null; then
        dnf install https://dl.k6.io/rpm/repo.rpm -y
        dnf install k6 -y
        echo "✅ k6 installed successfully"
    else
        echo "⏭️ k6 already installed"
    fi

    echo "📦 Installing Node.js 18..."
    if ! command -v node &> /dev/null; then
        dnf module enable nodejs:18 -y
        dnf module install nodejs:18 -y
        echo "✅ Node.js installed successfully (version: \$(node --version))"
    else
        echo "⏭️ Node.js already installed (version: \$(node --version))"
    fi

    echo "🚀 Installing chectl (Eclipse Che CLI)..."
    if ! command -v chectl &> /dev/null; then
        bash <(curl -sL https://che-incubator.github.io/chectl/install.sh)
        echo "✅ chectl installed successfully"
    else
        echo "⏭️ chectl already installed (version: \$(chectl version))"
    fi

    echo "🔐 Generating internal SSH keys..."
    if [ ! -f ~/.ssh/id_rsa ]; then
        ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa
    else
        echo "⏭️ SSH key already exists."
    fi

    echo "🔄 Authorizing root@localhost..."
    sshpass -p "$PASS" ssh-copy-id -o StrictHostKeyChecking=no root@localhost

    echo "📂 Cloning Jetlag repository..."
    if [ ! -d "jetlag" ]; then
        git clone https://github.com/redhat-performance/jetlag.git
    else
        echo "⏭️ Jetlag folder already exists."
    fi

    echo "📂 Cloning DevWorkspace Operator Load Tests repository..."
    if [ ! -d "/home/devworkspace-operator-load-tests" ]; then
        git clone https://github.com/rohankanojia-testing/devworkspace-operator-load-tests /home/devworkspace-operator-load-tests
    else
        echo "⏭️ DevWorkspace Operator Load Tests folder already exists."
    fi

    echo "📄 Organizing files..."

    # Move pull-secret to the jetlag root
    if [ -f "/root/pull-secret.txt" ]; then
        mv /root/pull-secret.txt /root/jetlag/pull-secret.txt
        echo "✅ pull-secret.txt -> /root/jetlag/"
    fi

    # Move SMCIPMITool to the ansible directory
    if [ -f "/root/smcipmitool.tar.gz" ]; then
        mv /root/smcipmitool.tar.gz /root/jetlag/ansible/smcipmitool.tar.gz
        echo "✅ SMCIPMITool -> /root/jetlag/ansible/"
    fi

    # Move all.yml to the jetlag ansible vars directory
    if [ -f "/root/all.yml" ]; then
        mkdir -p /root/jetlag/ansible/vars
        mv /root/all.yml /root/jetlag/ansible/vars/all.yml
        echo "✅ all.yml -> /root/jetlag/ansible/vars/"
    fi

    # Move jetlag-install.sh to jetlag root directory
    if [ -f "/root/jetlag-install.sh" ]; then
        mv /root/jetlag-install.sh /root/jetlag/jetlag-install.sh
        echo "✅ jetlag-install.sh -> /root/jetlag/"
    fi

    # Add /home/temp-scripts to PATH
    echo "🔧 Adding /home/temp-scripts to PATH..."
    if ! grep -q '/home/temp-scripts' ~/.bashrc; then
        echo 'export PATH="/home/temp-scripts:\$PATH"' >> ~/.bashrc
        echo "✅ /home/temp-scripts added to PATH in ~/.bashrc"
    else
        echo "⏭️ /home/temp-scripts already in PATH"
    fi

    echo "✨ --- SETUP COMPLETE --- ✨"
EOF

# 🏁 Final output
echo ""
echo "-------------------------------------------------------"
echo "✅ Done! Log in to start your work:"
echo ""
echo "   ssh root@$HOSTNAME"
echo ""
echo "-------------------------------------------------------"
