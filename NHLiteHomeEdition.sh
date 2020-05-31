#!/data/data/com.termux/files/usr/bin/bash -e

VERSION=2020011601
BASE_URL=https://images.kali.org/nethunter
USERNAME=kali

function unsupported_arch() {
    printf "${red}"
    echo "[*] Unsupported Architecture\n\n"
    printf "${reset}"
    exit
}

function ask() {
    # http://djm.me/ask
    while true; do

        if [ "${2:-}" = "S" ]; then
            prompt="S/n"
            default=Y
        elif [ "${2:-}" = "N" ]; then
            prompt="s/N"
            default=N
        else
            prompt="s/n"
            default=
        fi

        # Ask the question
        printf "${light_cyan}\n[?] "
        read -p "$1 [$prompt] " REPLY

        # Default?
        if [ -z "$REPLY" ]; then
            REPLY=$default
        fi

        printf "${reset}"

        # Check if the reply is valid
        case "$REPLY" in
            S*|s*) return 0 ;;
            N*|n*) return 1 ;;
        esac
    done
}

function get_arch() {
    printf "${blue}[*] Verificando a arquitetura do dispositivo ..."
    case $(getprop ro.product.cpu.abi) in
        arm64-v8a)
            SYS_ARCH=arm64
            ;;
        armeabi|armeabi-v7a)
            SYS_ARCH=armhf
            ;;
        *)
            unsupported_arch
            ;;
    esac
}

function set_strings() {
    CHROOT=kali-${SYS_ARCH}
    IMAGE_NAME=kalifs-${SYS_ARCH}-minimal.tar.xz
    SHA_NAME=kalifs-${SYS_ARCH}-minimal.sha512sum
}

function prepare_fs() {
    unset KEEP_CHROOT
    if [ -d ${CHROOT} ]; then
        if ask "Diretório rootfs existente encontrado. Excluir e criar um novo?" "N"; then
            rm -rf ${CHROOT}
        else
            KEEP_CHROOT=1
        fi
    fi
}

function cleanup() {
    if [ -f ${IMAGE_NAME} ]; then
        if ask "Excluir arquivo rootfs baixado?" "N"; then
            if [ -f ${IMAGE_NAME} ]; then
                rm -f ${IMAGE_NAME}
            fi
            if [ -f ${SHA_NAME} ]; then
                rm -f ${SHA_NAME}
            fi
        fi
    fi
}

function check_dependencies() {
    printf "${blue}\n[*] Verificando dependências do pacote...${reset}\n"
    apt update -y &> /dev/null

    for i in proot espeak tar axel; do
        if [ -e $PREFIX/bin/$i ]; then
            echo "  $i está OK"
        else
            printf "Instalando ${i}...\n"
            apt install -y $i || {
                printf "${red}ERRO: falha ao instalar pacotes.\n Saindo.\n${reset}"
                exit
            }
        fi
    done
    apt upgrade -y
}


function get_url() {
    ROOTFS_URL="${BASE_URL}/${IMAGE_NAME}"
    SHA_URL="${BASE_URL}/${SHA_NAME}"
}

function get_rootfs() {
    unset KEEP_IMAGE
    if [ -f ${IMAGE_NAME} ]; then
        if ask "Arquivo de imagem existente encontrado. Excluir e baixar um novo?" "N"; then
            rm -f ${IMAGE_NAME}
        else
            printf "${yellow}[!] Usando o arquivo rootfs existente${reset}\n"
            KEEP_IMAGE=1
            return
        fi
    fi
    printf "${blue}[*] Baixando rootfs...${reset}\n\n"
    get_url
    axel ${EXTRA_ARGS} --alternate "$ROOTFS_URL"
}

function get_sha() {
    if [ -z $KEEP_IMAGE ]; then
        printf "\n${blue}[*] Obtendo o SHA ... ${reset}\n\n"
        get_url
        if [ -f ${SHA_NAME} ]; then
            rm -f ${SHA_NAME}
        fi
        axel ${EXTRA_ARGS} --alternate "${SHA_URL}"
    fi
}

function verify_sha() {
    if [ -z $KEEP_IMAGE ]; then
        printf "\n${blue}[*] Verificando a integridade do rootfs...${reset}\n\n"
        sha512sum -c $SHA_NAME || {
            printf "${red} Rootfs corrompidos. Por favor, execute este instalador novamente ou faça o download do arquivo manualmente\n${reset}"
            exit 1
        }
    fi
}

function extract_rootfs() {
    if [ -z $KEEP_CHROOT ]; then
        printf "\n${blue}[*] Extraindo rootfs... ${reset}\n\n"
        proot --link2symlink tar -xf $IMAGE_NAME 2> /dev/null || :
    else
        printf "${yellow}[!] Usando o diretório rootfs existente${reset}\n"
    fi
}


function create_launcher() {
    NH_LAUNCHER=${PREFIX}/bin/nethunter
    NH_SHORTCUT=${PREFIX}/bin/nh
    cat > $NH_LAUNCHER <<- EOF
#!/data/data/com.termux/files/usr/bin/bash -e
cd \${HOME}
## termux-exec sets LD_PRELOAD so let's unset it before continuing
unset LD_PRELOAD
## Workaround for Libreoffice, also needs to bind a fake /proc/version
if [ ! -f $CHROOT/root/.version ]; then
    touch $CHROOT/root/.version
fi

## Default user is "kali"
user="$USERNAME"
home="/home/\$user"
start="sudo -u kali /bin/bash"

## NH can be launched as root with the "-r" cmd attribute
## Also check if user kali exists, if not start as root
if grep -q "kali" ${CHROOT}/etc/passwd; then
    KALIUSR="1";
else
    KALIUSR="0";
fi
if [[ \$KALIUSR == "0" || ("\$#" != "0" && ("\$1" == "-r" || "\$1" == "-R")) ]];then
    user="root"
    home="/\$user"
    start="/bin/bash --login"
    if [[ "\$#" != "0" && ("\$1" == "-r" || "\$1" == "-R") ]];then
        shift
    fi
fi

cmdline="proot \\
        --link2symlink \\
        -0 \\
        -r $CHROOT \\
        -b /dev \\
        -b /proc \\
        -b $CHROOT\$home:/dev/shm \\
        -w \$home \\
           /usr/bin/env -i \\
           HOME=\$home \\
           PATH=/usr/local/sbin:/usr/local/bin:/bin:/usr/bin:/sbin:/usr/sbin \\
           TERM=\$TERM \\
           LANG=pt_BR.UTF-8 \\
           \$start"

cmd="\$@"
if [ "\$#" == "0" ];then
    exec \$cmdline
else
    \$cmdline -c "\$cmd"
fi
EOF

    chmod 700 $NH_LAUNCHER
    if [ -L ${NH_SHORTCUT} ]; then
        rm -f ${NH_SHORTCUT}
    fi
    if [ ! -f ${NH_SHORTCUT} ]; then
        ln -s ${NH_LAUNCHER} ${NH_SHORTCUT} >/dev/null
    fi

}

function create_kex_launcher() {
    KEX_LAUNCHER=${CHROOT}/usr/bin/kex
    cat > $KEX_LAUNCHER <<- EOF
#!/bin/bash

function start-kex() {
    if [ ! -f ~/.vnc/passwd ]; then
        passwd-kex
    fi
    USR=\$(whoami)
    if [ \$USR == "root" ]; then
        SCREEN=":2"
    else
        SCREEN=":1"
    fi
    export HOME=\${HOME}; export USER=\${USR}; LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libgcc_s.so.1 nohup vncserver \$SCREEN >/dev/null 2>&1 </dev/null
    starting_kex=1
    return 0
}

function stop-kex() {
    vncserver -kill :1 | sed s/"Xtigervnc"/"NetHunter KeX"/
    vncserver -kill :2 | sed s/"Xtigervnc"/"NetHunter KeX"/
    return $?
}

function passwd-kex() {
    vncpasswd
    return $?
}

function status-kex() {
    sessions=\$(vncserver -list | sed s/"TigerVNC"/"NetHunter KeX"/)
    if [[ \$sessions == *"590"* ]]; then
        printf "\n\${sessions}\n"
        printf "\nVocê pode usar o cliente KeX para conectar-se a qualquer um desses monitores.\n\n"
    else
        if [ ! -z \$starting_kex ]; then
            printf '\nErro ao iniciar o servidor KeX.\nTente "nethunter kex kill" ou reinicie a sessão do termux e tente novamente.\n\n'
        fi
    fi
    return 0
}

function kill-kex() {
    pkill Xtigervnc
    return \$?
}

case \$1 in
    start)
        start-kex
        ;;
    stop)
        stop-kex
        ;;
    status)
        status-kex
        ;;
    passwd)
        passwd-kex
        ;;
    kill)
        kill-kex
        ;;
    *)
        stop-kex
        start-kex
        status-kex
        ;;
esac
EOF

    chmod 700 $KEX_LAUNCHER
}

function fix_profile_bash() {
    ## Prevent attempt to create links in read only filesystem
    if [ -f ${CHROOT}/root/.bash_profile ]; then
        sed -i '/if/,/fi/d' "${CHROOT}/root/.bash_profile"
    fi
}

function fix_sudo() {
    ## fix sudo & su on start
    chmod +s $CHROOT/usr/bin/sudo
    chmod +s $CHROOT/usr/bin/su
        echo "kali    ALL=(ALL:ALL) ALL" > $CHROOT/etc/sudoers.d/kali

    # https://bugzilla.redhat.com/show_bug.cgi?id=1773148
    echo "Set disable_coredump false" > $CHROOT/etc/sudo.conf
}

function fix_uid() {
    ## Change kali uid and gid to match that of the termux user
    USRID=$(id -u)
    GRPID=$(id -g)
    nh -r usermod -u $USRID kali 2>/dev/null
    nh -r groupmod -g $GRPID kali 2>/dev/null
}

function print_banner() {
    clear
    printf "${blue}##################################################\n"
    printf "${blue}##                                              ##\n"
    printf "${blue}##  88      a8P         db        88        88  ##\n"
    printf "${blue}##  88    .88'         d88b       88        88  ##\n"
    printf "${blue}##  88   88'          d8''8b      88        88  ##\n"
    printf "${blue}##  88 d88           d8'  '8b     88        88  ##\n"
    printf "${blue}##  8888'88.        d8YaaaaY8b    88        88  ##\n"
    printf "${blue}##  88P   Y8b      d8''''''''8b   88        88  ##\n"
    printf "${blue}##  88     '88.   d8'        '8b  88        88  ##\n"
    printf "${blue}##  88       Y8b d8'          '8b 888888888 88  ##\n"
    printf "${blue}##    HOME EDITION                              ##\n"
    printf "${blue}####  ############# NH HOME EDITION ##############${reset}\n\n"
}


##################################
##              CORES           ##

# CORES
red='\033[1;31m'
green='\033[1;32m'
yellow='\033[1;33m'
blue='\033[1;34m'
light_cyan='\033[1;96m'
reset='\033[0m'

EXTRA_ARGS=""
if [[ ! -z $1 ]]; then
    EXTRA_ARGS=$1
    if [[ $EXTRA_ARGS != "--insecure" ]]; then
        EXTRA_ARGS=""
    fi
fi

cd $HOME
print_banner
get_arch
set_strings
prepare_fs
check_dependencies
get_rootfs
get_sha
verify_sha
extract_rootfs
create_launcher
cleanup

printf "\n${blue}[*] Configurando NH Lite HOME EDITION ...\n"
fix_profile_bash
fix_sudo
create_kex_launcher
fix_uid

printf "\n${blue}[*] Instalando e configurando VNC Server ... ${reset}\n "
nh -r sudo apt update -y
nh -r sudo apt install tightvncserver -y
nh -r curl -LO https://raw.githubusercontent.com/NuddleRat/NHLite/master/xstartup
nh -r cp xstartup /home/kali/.vnc/
nh -r mv xstartup /root/.vnc/
nh -r chmod +x /home/kali/.vnc/xstartup
nh -r chmod +x /root/.vnc/xstartup

printf "\n${red}[*] Removendo recursos desnecessários do NH Lite HOME EDITION ...${reset}\n "
nh -r sudo apt remove --purge metasploit-framework -y
nh -r sudo apt autoremove -y 
nh -r sudo apt autoclean -y

printf "\n${blue}[*] Instalando recursos necessários para o NetHunter Lite ...${reset}\n"
nh -r sudo apt install vokoscreen-ng -y

printf "\n${blue}[*] Instalando interface gráfica XFCE4 ...${reset}\n"
nh -r sudo apt install kali-desktop-xfce kali-defaults kali-root-login desktop-base xfce4 xfce4-places-plugin xfce4-goodies -y

printf "n${blue}[*] Instalando recursos para o NH HOME EDITION ...${reset}\n"
nh -r sudo apt install calligra gimp inkscape pitivi -y

espeak -v m1+pt_br "bem-vindo ao NetHunter Lite HOME EDITION"
print_banner
printf "${green}[=] NH Lite HOME EDITION v1.0 instalado com sucesso${reset}\n\n"
printf "${green}[+] Para iniciar o NH Lite HOME EDITION v1.0, digite:${reset}\n"
printf "${green}[+] nethunter             # Para iniciar o NH Lite HOME EDITION cli${reset}\n"
printf "${green}[+] nethunter vncpasswd  # Para definir a senha do VNC${reset}\n"
printf "${green}[+] nethunter vncserver       # Para iniciar o NH Lite HOME EDITION gui${reset}\n"
printf "${green}[+] nethunter vncserver -kill :1    # Para parar o NH Lite HOME EDITION gui${reset}\n"
printf "${green}[+] nethunter -r          # Para executar o NH Lite HOME EDITION como root${reset}\n"
printf "${green}[+] nh                    # Atalho para o NH Lite HOME EDITION${reset}\n\n"
printf "${light_cyan}[!] NH HOME EDITION É UMA EDIÇÃO DO NH LITE v1.0, QUE ACOMPANHA A INTEFACE GRAFICA XFCE4 E PROGRAMAS PARA EDIÇÃO DE FOTOS E VÍDEOS, EDITORES DE TEXTO E GRAVADOR DE TELA, TUDO ISSO EM PORTUGUÊS.${reset}\n"
printf "${red}[!] Traduzido por Nuddle && Speatec System${reset}\n"
printf "${red}[!] Script original de Offensive Security${reset}\n"
echo ""
