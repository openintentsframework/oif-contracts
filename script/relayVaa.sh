# Set the required variables
chainId="$1"
address="$2"
sequence="$3"
network="$4"
address2="$5"
RPC_URL="$6"
PRIVATE_KEY="$7"

# Call the API and get the vaaBytes (base64 encoded)
vaaBytesBase64=$(curl -s -X 'GET' "https://api.testnet.wormholescan.io/v1/signed_vaa/${chainId}/${address}/${sequence}?network=${network}" -H 'accept: application/json' | jq -r '.vaaBytes')

# Check if vaaBytes is empty or not
if [[ -z "$vaaBytesBase64" ]]; then
  echo "Error: vaaBytes not found in response."
  exit 1
fi

# Convert base64 to hex
vaaBytesHex=$(echo "$vaaBytesBase64" | base64 -d | xxd -p | tr -d '\n')

echo $vaaBytesHex

# cast call "${address2}" "receiveMessage(bytes)" "0x${vaaBytesHex}" --rpc-url "$RPC_URL" --trace
# Execute the cast command to send the message
# cast send "${address2}" "receiveMessage(bytes)" "0x${vaaBytesHex}" --rpc-url "$RPC_URL" --private-key "${PRIVATE_KEY}"

# alt
forge script WormholeRelayer --sig "relay(address,bytes)" "${address2}" "0x${vaaBytesHex}" --rpc-url "$RPC_URL" --private-key "${PRIVATE_KEY}" -vvvv --broadcast