#!/usr/bin/env bash
# Kids Landline — automated VoIP.ms setup script
# Run this if the browser-based setup can't reach the voip.ms API (CORS).
#
# Usage: ./setup.sh

set -euo pipefail

API="https://voip.ms/api/v1/rest.php"

echo "=== Kids Landline Setup ==="
echo ""

# Collect credentials
read -p "VoIP.ms email (API username): " API_USER
read -sp "API password (set under SOAP and REST/JSON API, not login password): " API_PASS
echo ""

# Test connection
echo ""
echo "Testing API connection..."
BALANCE=$(curl -sf "$API?api_username=$API_USER&api_password=$API_PASS&method=getBalance" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('balance',{}).get('current_balance','?')) if d['status']=='success' else (print('FAILED: ' + d.get('message',d['status'])), exit(1))")
echo "Connected. Balance: \$$BALANCE"

# List servers
echo ""
echo "Loading servers..."
SERVERS=$(curl -sf "$API?api_username=$API_USER&api_password=$API_PASS&method=getServersInfo")
echo "$SERVERS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if data['status'] != 'success':
    print('Failed to load servers'); sys.exit(1)
for s in data['servers']:
    print(f\"  {s['server_pop']:>3}  {s['server_name']:<30} {s['server_hostname']}\")
"

read -p "Enter server ID (number from left column): " SERVER_POP
SERVER_HOST=$(echo "$SERVERS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
pop = '$SERVER_POP'
for s in data['servers']:
    if str(s['server_pop']) == pop:
        print(s['server_hostname']); break
")
echo "Selected: $SERVER_HOST"

# Search for phone numbers
echo ""
read -p "Area code to search (e.g. 212, 415, 305): " AREA_CODE
echo "Searching for numbers in $AREA_CODE..."
DIDS=$(curl -sf "$API?api_username=$API_USER&api_password=$API_PASS&method=getDIDsUSA&state=$AREA_CODE")
echo "$DIDS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if data['status'] != 'success' or not data.get('dids'):
    print('No numbers found. Try another area code.'); sys.exit(1)
for i, d in enumerate(data['dids'][:15]):
    num = d['did']
    formatted = f'({num[:3]}) {num[3:6]}-{num[6:]}'
    print(f\"  {i+1:>2}. {formatted}  \${d['monthly']}/mo\")
"

read -p "Pick a number (1-15): " DID_CHOICE
DID=$(echo "$DIDS" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data['dids'][int('$DID_CHOICE')-1]['did'])
")
echo "Selected: $DID"

# Kid's info
echo ""
read -p "Kid's name (for the phone line): " KID_NAME
read -p "Voicemail notification email: " VM_EMAIL

# Generate sub-account name
SUB_USER=$(echo "$KID_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9' | cut -c1-10)
SUB_USER="${SUB_USER}ph"

# Generate password
SUB_PASS=$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-16)
echo "Generated sub-account password: $SUB_PASS"

# Create sub-account
echo ""
echo "Creating sub-account '$SUB_USER'..."
RESULT=$(curl -sf "$API?api_username=$API_USER&api_password=$API_PASS&method=createSubAccount&username=$SUB_USER&password=$SUB_PASS&protocol=1&auth_type=1&device_type=2&lock_international=1&description=$(echo "$KID_NAME Phone" | sed 's/ /%20/g')&callerid_number=$DID")
STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
if [ "$STATUS" != "success" ]; then
  echo "Failed: $(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message','unknown'))")"
  exit 1
fi
echo "Sub-account created."

# Get full sub-account name
MAIN_USER=$(echo "$API_USER" | cut -d@ -f1)
FULL_SUB="${MAIN_USER}_${SUB_USER}"

# Order DID
echo "Ordering phone number $DID..."
RESULT=$(curl -sf "$API?api_username=$API_USER&api_password=$API_PASS&method=orderDID&did=$DID&routing=account:$FULL_SUB&pop=$SERVER_POP&dialtime=60&billing_type=1")
STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
if [ "$STATUS" != "success" ]; then
  echo "Failed: $(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message','unknown'))")"
  echo "Sub-account was created. Clean up manually if needed."
  exit 1
fi
echo "Phone number ordered."

# Create voicemail
echo "Creating voicemail..."
TZ=$(python3 -c "import time; print(time.tzname[0])" 2>/dev/null || echo "US/Eastern")
RESULT=$(curl -sf "$API?api_username=$API_USER&api_password=$API_PASS&method=createVoicemail&digits=1&name=$(echo "$KID_NAME Voicemail" | sed 's/ /%20/g')&password=1234&skip_password=no&attach_message=yes&delete_message=no&email=$VM_EMAIL&language=en")
STATUS=$(echo "$RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
if [ "$STATUS" = "success" ]; then
  echo "Voicemail created (PIN: 1234)."
else
  echo "Voicemail setup skipped (may need manual config). Not critical."
fi

# Print Grandstream config
echo ""
echo "============================================"
echo "  SETUP COMPLETE — HERE'S YOUR CONFIG"
echo "============================================"
echo ""
echo "Phone Number:  $(echo "$DID" | sed 's/\([0-9]\{3\}\)\([0-9]\{3\}\)\([0-9]\{4\}\)/(\1) \2-\3/')"
echo "Sub-Account:   $FULL_SUB"
echo "Password:      $SUB_PASS"
echo "SIP Server:    $SERVER_HOST"
echo "Voicemail PIN: 1234"
echo ""
echo "============================================"
echo "  GRANDSTREAM HT802 CONFIGURATION"
echo "============================================"
echo ""
echo "1. Plug Grandstream into router (ethernet) and power on"
echo "2. Plug phone into Port 1"
echo "3. Pick up phone, dial ***02 to hear the IP address"
echo "4. Open http://<that-ip> in a browser"
echo "5. Login: admin / (password on sticker on bottom of device)"
echo "6. Go to FXS PORT1 tab and set:"
echo ""
echo "   Primary SIP Server:              $SERVER_HOST"
echo "   Prefer Primary SIP Server:       Yes"
echo "   Outbound Proxy:                  $SERVER_HOST"
echo "   NAT Traversal:                   Keep-Alive"
echo "   SIP User ID:                     $FULL_SUB"
echo "   Authenticate ID:                 $FULL_SUB"
echo "   Authenticate Password:           $SUB_PASS"
echo "   DNS Mode:                        A Record"
echo "   SIP Registration:                Yes"
echo "   Unregister On Reboot:            No"
echo "   Outgoing Call Without Reg:        Yes"
echo "   Register Expiration:             5"
echo "   Local RTP Port:                  10000"
echo "   SIP OPTIONS/NOTIFY Keep Alive:   OPTIONS"
echo "   Allow SIP from Proxy Only:       Yes"
echo "   Preferred DTMF method:           In-audio, RFC2833"
echo "   Enable Call Features:            No"
echo "   Dial Plan:                       {[x*]+}"
echo "   Preferred Vocoder:               PCMU, PCMA, G729"
echo "   SUBSCRIBE for MWI:               Yes"
echo ""
echo "   --- Encryption (recommended) ---"
echo "   SIP Transport:                   TLS"
echo "   SRTP Mode:                       Enabled and Forced"
echo "   Local SIP Port:                  5061"
echo ""
echo "   --- Block direct IP calls ---"
echo "   Check SIP User ID for INVITE:    Yes"
echo ""
echo "7. Click Update, then Reboot"
echo "8. Wait 30 seconds — Phone 1 light should turn solid blue"
echo "9. Pick up phone — you should hear a dial tone"
echo "10. Dial: area code + number (US/Canada)"
echo "    International: 011 + country code + number"
echo ""
echo "Save this output somewhere safe!"
