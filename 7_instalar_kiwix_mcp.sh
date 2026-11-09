#!/bin/bash

# =================================================================
# SCRIPT DE INSTALACIÓN: KIWIX MCP HTTP SERVER + SYSTEMD
# =================================================================

# --- 0. VERIFICACIÓN DE USUARIO ---
if [[ $EUID -eq 0 ]]; then
   echo "🚫 ERROR: ¡No ejecute este script como root (usando 'sudo')!"
   echo "Ejecútelo como su usuario normal. Pedirá la contraseña de sudo cuando sea necesario."
   exit 1
fi

# --- CONFIGURACIÓN DE RUTAS DENTRO DE ~/.local/ ---
INSTALL_DIR="$HOME/.local/share/kiwix-mcp"
VENV_DIR="$INSTALL_DIR/.venv"
SERVICE_NAME="kiwix-mcp.service"

echo "🚀 Instalando Kiwix MCP Server en $INSTALL_DIR..."

# ----------------------------------------------------------------
# PASO 1: CREAR DIRECTORIO Y ENTORNO VIRTUAL PYTHON
# ----------------------------------------------------------------
preparar_entorno() {
    echo "1/4: Creando directorios y venv Python..."
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$HOME/.local/bin"

    if [ ! -d "$VENV_DIR" ]; then
        python3 -m venv "$VENV_DIR"
        echo "✅ Entorno virtual creado en $VENV_DIR"
    fi
}

# ----------------------------------------------------------------
# PASO 2: INSTALAR PAQUETES PYTHON (DEPENDENCIAS)
# ----------------------------------------------------------------
instalar_dependencias() {
    echo "2/4: Instalando dependencias de Python..."
    
    "$VENV_DIR/bin/pip" install --upgrade pip
    
    # Instalación de los paquetes requeridos por el stack MCP de Kiwix
    "$VENV_DIR/bin/pip" install \
        "mcp[cli]" \
        fastapi \
        uvicorn \
        httpx \
        httpx-sse \
        requests \
        beautifulsoup4 \
        pydantic \
        pydantic-settings \
        python-dotenv

    echo "✅ Dependencias instaladas correctamente."
}

# ----------------------------------------------------------------
# PASO 3: CONFIGURAR SERVICIO SYSTEMD
# ----------------------------------------------------------------
configurar_servicio() {
    echo "3/4: Creando servicio systemd ($SERVICE_NAME)..."

    SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"

    sudo bash -c "cat << EOF > $SERVICE_FILE
[Unit]
Description=Servidor MCP HTTP para Kiwix
After=network.target kiwix.service

[Service]
Type=simple
User=$USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$VENV_DIR/bin/python $INSTALL_DIR/server.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF"

    sudo systemctl daemon-reload
    sudo systemctl enable "$SERVICE_NAME"
    echo "✅ Servicio $SERVICE_NAME activado."
}

# ----------------------------------------------------------------
# PASO 4: INICIAR Y VERIFICAR
# ----------------------------------------------------------------
iniciar_servicio() {
    echo "4/4: Iniciando el servicio..."
    
    # Si ya existe un server.py, reiniciamos el servicio
    if [ -f "$INSTALL_DIR/server.py" ]; then
        sudo systemctl restart "$SERVICE_NAME"
        echo "✅ Servicio reiniciado."
    else
        echo "ℹ️ Recuerda copiar o crear tu archivo 'server.py' en $INSTALL_DIR y ejecutar:"
        echo "   sudo systemctl restart $SERVICE_NAME"
    fi
}

# =================================================================
# EJECUCIÓN PRINCIPAL
# =================================================================
preparar_entorno
instalar_dependencias
configurar_servicio
iniciar_servicio

echo ""
echo "=========================================================="
echo "🥳 Instalación de Kiwix MCP finalizada."
echo "Ruta del proyecto: $INSTALL_DIR"
echo "Comprobar estado: sudo systemctl status $SERVICE_NAME"
echo "=========================================================="
