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

echo "🖥️ Phase 2: Remote Configuration on $HOSTNAME..."

# 🤖 4. Execute remote setup via SSH
ssh "root@$HOSTNAME" << EOF
    echo "📦 Installing dependencies (tmux, git, python3-pip, sshpass)..."
    dnf install tmux git python3-pip sshpass -y

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
