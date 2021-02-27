#!/bin/bash

# Script is brought to you by ATADA_Stakepool, Telegram @atada_stakepool

#load variables from common.sh
#       socket          Path to the node.socket (also exports socket to CARDANO_NODE_SOCKET_PATH)
#       genesisfile     Path to the genesis.json
#       magicparam      TestnetMagic parameter
#       cardanocli      Path to the cardano-cli executable
. "$(dirname "$0")"/00_common.sh

case $# in
  2|3|4 ) stakeAddr="$(dirname $1)/$(basename $1 .staking).staking"; stakeAddr=${stakeAddr/#.\//}
	toAddr="$(dirname $2)/$(basename $2 .addr)"; toAddr=${toAddr/#.\//};;
  * ) cat >&2 <<EOF
Usage:  $(basename $0) <StakeAddressName> <To AddressName> [optional: <FeePaymentAddressName>] [optional: list of UTXOs to use]
Ex.: $(basename $0) atada.staking atada.payment        (claims the rewards from atada.staking.addr and sends them to atada.payment.addr, atada.payment.addr pays the fees)
Ex.: $(basename $0) atada.staking atada.payment funds  (claims the rewards from atada.staking.addr and sends them to atada.payment.addr, funds.addr pays the fees)

Optional parameter UTXO List:

In rare cases you wanna define the exact UTXOs that should be used for sending Assets out, you can do that as a 6th parameter in the scheme:
"UTXO1#Index" ... to specify one UTXO, must be in "..."
"UTXO1#Index|UTXO2#Index" ... to specify more UTXOs provide them with the | as separator, must be in "..."

EOF
  exit 1;; esac

#Check if toAddr file doesn not exists, make a dummy one in the temp directory and fill in the given parameter as the hash address
if [ ! -f "${toAddr}.addr" ]; then echo "$(basename ${toAddr})" > ${tempDir}/tempTo.addr; toAddr="${tempDir}/tempTo"; fi

#Check if an optional fee payment address is given and different to the receiver address
fromAddr=${toAddr}

if [ $# -ge 3 ] && [[ ! "${3^^}" == *"#"* ]] && [[ ! ${3} == "" ]]; then fromAddr="$(dirname $3)/$(basename $3 .addr)"; fromAddr=${fromAddr/#.\//}; fi
if [[ "${fromAddr}" == "${toAddr}" ]]; then rxcnt="1"; else rxcnt="2"; fi

#Checks for needed files
if [ ! -f "${toAddr}.addr" ]; then echo -e "\n\e[35mERROR - \"${toAddr}.addr\" does not exist!\e[0m"; exit 1; fi

if [ ! -f "${stakeAddr}.addr" ]; then echo -e "\n\e[35mERROR - \"${stakeAddr}.addr\" does not exist!\e[0m"; exit 1; fi
if ! [[ -f "${stakeAddr}.skey" || -f "${stakeAddr}.hwsfile" ]]; then echo -e "\n\e[35mERROR - \"${stakeAddr}.skey/hwsfile\" Staking Signing Key or HardwareFile does not exist! Please create it first with script 03a.\e[0m"; exit 2; fi

if [ ! -f "${fromAddr}.addr" ]; then echo -e "\n\e[35mERROR - \"${fromAddr}.addr\" does not exist!\e[0m"; exit 1; fi
if ! [[ -f "${fromAddr}.skey" || -f "${fromAddr}.hwsfile" ]]; then echo -e "\n\e[35mERROR - \"${fromAddr}.skey/hwsfile\" does not exist! Please create it first with script 03a or 02.\e[0m"; exit 1; fi



echo -e "\e[0mClaim Staking Rewards from Address\e[32m ${stakeAddr}.addr\e[0m with funds from Address\e[32m ${fromAddr}.addr\e[0m"
echo

lastCallParam=${@: -1};
if [ $# -ge 3 ] && [[ "${lastCallParam}" == *"#"* ]]; then filterForUTXO="${lastCallParam}"; else filterForUTXO=""; fi

#get live values
currentTip=$(get_currentTip)
ttl=$(get_currentTTL)
currentEPOCH=$(get_currentEpoch)

echo -e "Current Slot-Height:\e[32m ${currentTip}\e[0m (setting TTL[invalid_hereafter] to ${ttl})"

sendFromAddr=$(cat ${fromAddr}.addr); check_address "${sendFromAddr}"
sendToAddr=$(cat ${toAddr}.addr); check_address "${sendToAddr}"
stakingAddr=$(cat ${stakeAddr}.addr); check_address "${stakingAddr}"

echo
echo -e "Claim all rewards from Address ${stakeAddr}.addr: \e[32m${stakingAddr}\e[0m"
echo
echo -e "Send the rewards to Address ${toAddr}.addr: \e[32m${sendToAddr}\e[0m"
echo -e "Pay fees from Address ${fromAddr}.addr: \e[32m${sendFromAddr}\e[0m"
echo

        #Get rewards state data for the address. When in online mode of course from the node and the chain, in offlinemode from the transferFile
        if ${onlineMode}; then
                                rewardsJSON=$(${cardanocli} ${subCommand} query stake-address-info --address ${stakingAddr} --cardano-mode ${magicparam} ${nodeEraParam} | jq -rc .)
                          else
                                rewardsJSON=$(cat ${offlineFile} | jq -r ".address.\"${stakingAddr}\".rewardsJSON" 2> /dev/null)
                                if [[ "${rewardsJSON}" == null ]]; then echo -e "\e[35mStake-Address not included in the offline transferFile, please include it first online!\e[0m\n"; exit; fi
        fi
        checkError "$?"; if [ $? -ne 0 ]; then exit $?; fi
        rewardsEntryCnt=$(jq -r 'length' <<< ${rewardsJSON})

        if [[ ${rewardsEntryCnt} == 0 ]]; then echo -e "\e[35mStaking Address is not on the chain, register it first !\e[0m\n"; exit 1;
        else echo -e "\e[0mFound:\e[32m ${rewardsEntryCnt}\e[0m entries\n";
        fi

        rewardsSum=0

        for (( tmpCnt=0; tmpCnt<${rewardsEntryCnt}; tmpCnt++ ))
        do
        rewardsAmount=$(jq -r ".[${tmpCnt}].rewardAccountBalance" <<< ${rewardsJSON})

        delegationPoolID=$(jq -r ".[${tmpCnt}].delegation" <<< ${rewardsJSON})

        rewardsSum=$((${rewardsSum}+${rewardsAmount}))

        echo -ne "[$((${tmpCnt}+1))]\t"

        #Checking about rewards on the stake address
        if [[ ${rewardsAmount} == 0 ]]; then echo -e "\e[35mNo rewards found on the stake Addr !\e[0m";
        else echo -e "Entry Rewards: \e[33m$(convertToADA ${rewardsAmount}) ADA / ${rewardsAmount} lovelaces\e[0m"
        fi

        #If delegated to a pool, show the current pool ID
        if [[ ! ${delegationPoolID} == null ]]; then echo -e "   \tAccount is delegated to a Pool with ID: \e[32m${delegationPoolID}\e[0m"; fi

        echo

        done

	if [[ ${rewardsSum} -eq 0 ]]; then exit 1; fi;

        if [[ ${rewardsEntryCnt} -gt 1 ]]; then echo -e "   \t-----------------------------------------\n"; echo -e "   \tTotal Rewards: \e[33m$(convertToADA ${rewardsSum}) ADA / ${rewardsSum} lovelaces\e[0m\n"; fi


#-------------------------------------

#
# Checking UTXO Data of the source address and gathering data about total lovelaces and total assets
#
        #Get UTX0 Data for the address. When in online mode of course from the node and the chain, in offlinemode from the transferFile
        if ${onlineMode}; then
                                utxo=$(${cardanocli} ${subCommand} query utxo --address ${sendFromAddr} --cardano-mode ${magicparam} ${nodeEraParam}); checkError "$?"; if [ $? -ne 0 ]; then exit $?; fi;
                                utxoJSON=$(generate_UTXO "${utxo}" "${sendFromAddr}")
                          else
                                readOfflineFile;        #Reads the offlinefile into the offlineJSON variable
                                utxoJSON=$(jq -r ".address.\"${sendFromAddr}\".utxoJSON" <<< ${offlineJSON})
                                if [[ "${utxoJSON}" == null ]]; then echo -e "\e[35mPayment-Address not included in the offline transferFile, please include it first online!\e[0m\n"; exit; fi
        fi

        #Convert UTXO into mary style if UTXO is shelley/allegra style
        if [[ ! "$(jq -r '[.[]][0].amount | type' <<< ${utxoJSON})" == "array" ]]; then utxoJSON=$(convert_UTXO "${utxoJSON}"); fi

        #Only use UTXOs specied in the extra parameter if present
        if [[ ! "${filterForUTXO}" == "" ]]; then echo -e "\e[0mUTXO-Mode: \e[32mOnly using the UTXO with Hash ${filterForUTXO}\e[0m\n"; utxoJSON=$(filterFor_UTXO "${utxoJSON}" "${filterForUTXO}"); fi

	#Only use UTXOs with lovelaces in it if Scripts was called with the last parameter keyword "ONLYADA"
	#if [[ "${lastCallParam^^}" == "ONLYADA" ]]; then echo -e "\e[0mUTXO-Mode: \e[32mOnly UTXOs with ADA(lovelaces) on it, no Assets\e[0m\n"; utxoJSON=$(onlyLovelaces_UTXO "${utxoJSON}"); fi

        txcnt=$(jq length <<< ${utxoJSON}) #Get number of UTXO entries (Hash#Idx), this is also the number of --tx-in for the transaction
        if [[ ${txcnt} == 0 ]]; then echo -e "\e[35mNo funds on the Source Address!\e[0m\n"; exit; else echo -e "\e[32m${txcnt} UTXOs\e[0m found on the Source Address!\n"; fi

	#Calculating the total amount of lovelaces in all utxos on this address
        totalLovelaces=0

        totalAssetsJSON="{}"; 	#Building a total JSON with the different assetstypes "policyIdHash.name", amount and name
        totalPolicyIDsJSON="{}"; #Holds the different PolicyIDs as values "policyIDHash", length is the amount of different policyIDs

	assetsOutString="";	#This will hold the String to append on the --tx-out if assets present or it will be empty

        #For each utxo entry, check the utxo#index and check if there are also any assets in that utxo#index
        #LEVEL 1 - different UTXOs
        for (( tmpCnt=0; tmpCnt<${txcnt}; tmpCnt++ ))
        do
        utxoHashIndex=$(jq -r "keys[${tmpCnt}]" <<< ${utxoJSON})
        utxoAmount=$(jq -r ".\"${utxoHashIndex}\".amount[0]" <<< ${utxoJSON})   #Lovelaces
	totalLovelaces=$(bc <<< "${totalLovelaces} + ${utxoAmount}")
        echo -e "Hash#Index: ${utxoHashIndex}\tAmount: ${utxoAmount}"
        assetsJSON=$(jq -r ".\"${utxoHashIndex}\".amount[1]" <<< ${utxoJSON})
        assetsEntryCnt=$(jq length <<< ${assetsJSON})
        if [[ ${assetsEntryCnt} -gt 0 ]]; then
                        #LEVEL 2 - different policyID/assetHASH
                        for (( tmpCnt2=0; tmpCnt2<${assetsEntryCnt}; tmpCnt2++ ))
                        do
                        assetHash=$(jq -r ".[${tmpCnt2}][0]" <<< ${assetsJSON})  #assetHash = policyID
                        assetsNameCnt=$(jq ".[${tmpCnt2}][1] | length" <<< ${assetsJSON})
                        totalPolicyIDsJSON=$( jq ". += {\"${assetHash}\": 1}" <<< ${totalPolicyIDsJSON})

                                #LEVEL 3 - different names under the same policyID
                                for (( tmpCnt3=0; tmpCnt3<${assetsNameCnt}; tmpCnt3++ ))
                                do
                                assetName=$(jq -r ".[${tmpCnt2}][1][${tmpCnt3}][0]" <<< ${assetsJSON})
                                assetAmount=$(jq -r ".[${tmpCnt2}][1][${tmpCnt3}][1]" <<< ${assetsJSON})
				if [[ "${assetName}" == "" ]]; then point=""; else point="."; fi
                                oldValue=$(jq -r ".\"${assetHash}${point}${assetName}\".amount" <<< ${totalAssetsJSON})
                                newValue=$(bc <<< "${oldValue}+${assetAmount}")
                                totalAssetsJSON=$( jq ". += {\"${assetHash}${point}${assetName}\":{amount: \"${newValue}\", name: \"${assetName}\"}}" <<< ${totalAssetsJSON})
                                echo -e "\e[90m            PolID: ${assetHash}\tAmount: ${assetAmount} ${assetName}\e[0m"
                                done
                         done
        fi
        txInString="${txInString} --tx-in ${utxoHashIndex}"
        done
        echo -e "\e[0m-----------------------------------------------------------------------------------------------------"
        echo -e "Total ADA on the Address:\e[32m $(convertToADA ${totalLovelaces}) ADA / ${totalLovelaces} lovelaces \e[0m\n"

        totalPolicyIDsCnt=$(jq length <<< ${totalPolicyIDsJSON});
        totalAssetsCnt=$(jq length <<< ${totalAssetsJSON})
        if [[ ${totalAssetsCnt} -gt 0 ]]; then
                        echo -e "\e[32m${totalAssetsCnt} Asset-Type(s) / ${totalPolicyIDsCnt} different PolicyIDs\e[0m found on the Address!\n"
                        printf "\e[0m%-70s %16s %s\n" "PolicyID.Name:" "Total-Amount:" "Name:"
                        for (( tmpCnt=0; tmpCnt<${totalAssetsCnt}; tmpCnt++ ))
                        do
                        assetHashName=$(jq -r "keys[${tmpCnt}]" <<< ${totalAssetsJSON})
                        assetAmount=$(jq -r ".\"${assetHashName}\".amount" <<< ${totalAssetsJSON})
                        assetName=$(jq -r ".\"${assetHashName}\".name" <<< ${totalAssetsJSON})
                        printf "\e[90m%-70s \e[32m%16s %s\e[0m\n" "${assetHashName}" "${assetAmount}" "${assetName}"
                        if [[ $(bc <<< "${assetAmount}>0") -eq 1 ]]; then assetsOutString+="+${assetAmount} ${assetHashName}"; fi #only include in the sendout if more than zero
                        done
        fi
echo

#Read ProtocolParameters
if ${onlineMode}; then
                        protocolParametersJSON=$(${cardanocli} ${subCommand} query protocol-parameters --cardano-mode ${magicparam} ${nodeEraParam}); #onlinemode
                  else
                        protocolParametersJSON=$(jq ".protocol.parameters" <<< ${offlineJSON}); #offlinemode
                  fi
checkError "$?"; if [ $? -ne 0 ]; then exit $?; fi
minOutUTXO=$(get_minOutUTXO "${protocolParametersJSON}" "${totalAssetsCnt}" "${totalPolicyIDsCnt}")

#-------------------------------------

#withdrawal string
withdrawal="${stakingAddr}+${rewardsSum}"

#Generate Dummy-TxBody file for fee calculation
txBodyFile="${tempDir}/dummy.txbody"
rm ${txBodyFile} 2> /dev/null
if [[ ${rxcnt} == 1 ]]; then
                        ${cardanocli} ${subCommand} transaction build-raw ${nodeEraParam} ${txInString} --tx-out "${sendToAddr}+0${assetsOutString}" --invalid-hereafter ${ttl} --fee 0 --withdrawal ${withdrawal} --out-file ${txBodyFile}
			checkError "$?"; if [ $? -ne 0 ]; then exit $?; fi
                        else
                        ${cardanocli} ${subCommand} transaction build-raw ${nodeEraParam} ${txInString} --tx-out "${sendFromAddr}+0${assetsOutString}" --tx-out ${sendToAddr}+0 --invalid-hereafter ${ttl} --fee 0 --withdrawal ${withdrawal} --out-file ${txBodyFile}
			checkError "$?"; if [ $? -ne 0 ]; then exit $?; fi
fi
fee=$(${cardanocli} ${subCommand} transaction calculate-min-fee --tx-body-file ${txBodyFile} --protocol-params-file <(echo ${protocolParametersJSON}) --tx-in-count ${txcnt} --tx-out-count ${rxcnt} ${magicparam} --witness-count 2 --byron-witness-count 0 | awk '{ print $1 }')

echo -e "\e[0mMimimum transfer Fee for ${txcnt}x TxIn & ${rxcnt}x TxOut & Withdrawal: \e[32m $(convertToADA ${fee}) ADA / ${fee} lovelaces \e[90m"

#If only one address (paying for the fees and also receiving the rewards)
#If two different addresse (fromAddr is paying for the fees, toAddr is getting the rewards)
if [[ ${rxcnt} == 1 ]]; then

			#calculate the lovelaces to return to the payment address
			lovelacesToReturn=$(( ${totalLovelaces}-${fee}+${rewardsSum} ))
			#Checking about minimum funds in the UTX0
                        echo -e "\e[0mLovelaces that will be returned to destination Address (UTXO-Sum - fees + rewards): \e[33m $(convertToADA ${lovelacesToReturn}) ADA / ${lovelacesToReturn} lovelaces \e[90m"
			if [[ ${lovelacesToReturn} -lt ${minOutUTXO} ]]; then echo -e "\e[35mNot enough funds on the source Addr! Minimum UTXO value is ${minOutUTXO} lovelaces.\e[0m"; exit; fi

			echo

			else

                        #calculate the lovelaces to return to the fee payment address
                        lovelacesToReturn=$(( ${totalLovelaces}-${fee} ))
                        #Checking about minimum funds in the UTX0
                        echo -e "\e[0mLovelaces that will be sent to the destination Address (rewards): \e[33m $(convertToADA ${rewardsSum}) ADA / ${rewardsSum} lovelaces \e[90m"
                        echo -e "\e[0mLovelaces that will be returned to the fee payment Address (UTXO-Sum - fees): \e[32m $(convertToADA ${lovelacesToReturn}) ADA / ${lovelacesToReturn} lovelaces \e[90m"
                        if [[ ${lovelacesToReturn} -lt ${minOutUTXO} ]]; then echo -e "\e[35mNot enough funds on the source Addr! Minimum UTXO value is ${minOutUTXO} lovelaces.\e[0m"; exit; fi
                        echo

fi

txBodyFile="${tempDir}/$(basename ${fromAddr}).txbody"
txFile="${tempDir}/$(basename ${fromAddr}).tx"
echo
echo -e "\e[0mBuilding the unsigned transaction body: \e[32m ${txBodyFile} \e[90m"
echo

#Building unsigned transaction body

if [[ ${rxcnt} == 1 ]]; then
			${cardanocli} ${subCommand} transaction build-raw ${nodeEraParam} ${txInString} --tx-out "${sendToAddr}+${lovelacesToReturn}${assetsOutString}" --invalid-hereafter ${ttl} --fee ${fee} --withdrawal ${withdrawal} --out-file ${txBodyFile}
			else
                        ${cardanocli} ${subCommand} transaction build-raw ${nodeEraParam} ${txInString} --tx-out "${sendFromAddr}+${lovelacesToReturn}${assetsOutString}" --tx-out ${sendToAddr}+${rewardsSum} --invalid-hereafter ${ttl} --fee ${fee} --withdrawal ${withdrawal} --out-file ${txBodyFile}
fi

cat ${txBodyFile}
echo

echo -e "\e[0mSign the unsigned transaction body with the \e[32m${fromAddr}.skey/hwsfile\e[0m & \e[32m${stakeAddr}.skey/hwsfile\e[0m: \e[32m ${txFile} \e[90m"
echo

#If stakeaddress and payment address are from the same hardware files
paymentName=$(basename ${fromAddr} .payment) #contains the name before the .payment.addr extension
stakingName=$(basename ${stakeAddr} .staking) #contains the name before the .staking.addr extension
if [[ -f "${fromAddr}.hwsfile" && -f "${stakeAddr}.hwsfile" && "${paymentName}" == "${stakingName}" ]]; then
        start_HwWallet; checkError "$?"; if [ $? -ne 0 ]; then exit $?; fi
        tmp=$(${cardanohwcli} transaction sign --tx-body-file ${txBodyFile} --hw-signing-file ${fromAddr}.hwsfile --hw-signing-file ${stakeAddr}.hwsfile --change-output-key-file ${fromAddr}.hwsfile --change-output-key-file ${stakeAddr}.hwsfile ${magicparam} --out-file ${txFile} 2> /dev/stdout)
        if [[ "${tmp^^}" == *"ERROR"* ]]; then echo -e "\e[35m${tmp}\e[0m\n"; exit 1; else echo -e "\e[32mDONE\e[0m\n"; fi
        checkError "$?"; if [ $? -ne 0 ]; then exit $?; fi

elif [[ -f "${stakeAddr}.skey" && -f "${fromAddr}.skey" ]]; then #with the normal cli skey
        ${cardanocli} ${subCommand} transaction sign --tx-body-file ${txBodyFile} --signing-key-file ${fromAddr}.skey --signing-key-file ${stakeAddr}.skey ${magicparam} --out-file ${txFile}
else
echo -e "\e[35mThis combination is not allowed! A Hardware-Wallet can only be used to claim its own staking rewards on the chain.\e[0m\n"; exit 1;
fi
checkError "$?"; if [ $? -ne 0 ]; then exit $?; fi
echo -ne "\e[90m"
cat ${txFile}
echo

#Sign the unsigned transaction body with the SecureKey
#${cardanocli} ${subCommand} transaction sign --tx-body-file ${txBodyFile} --signing-key-file ${fromAddr}.skey --signing-key-file ${stakeAddr}.skey  ${magicparam} --out-file ${txFile}
#cat ${txFile}
#echo

if ask "\e[33mDoes this look good for you, continue ?" N; then
        echo
        if ${onlineMode}; then  #onlinesubmit
                                echo -ne "\e[0mSubmitting the transaction via the node..."
                                ${cardanocli} ${subCommand} transaction submit --tx-file ${txFile} --cardano-mode ${magicparam}
                                checkError "$?"; if [ $? -ne 0 ]; then exit $?; fi
                                echo -e "\e[32mDONE\n"

				#Show the TxID
				txID=$(${cardanocli} ${subCommand} transaction txid --tx-file ${txFile}); echo -e "\e[0mTxID is: \e[32m${txID}\e[0m"
				checkError "$?"; if [ $? -ne 0 ]; then exit $?; fi;
				if [[ ${magicparam} == "--mainnet" ]]; then echo -e "\e[0mTracking: \e[32mhttps://cardanoscan.io/transaction/${txID}\n"; fi

                          else  #offlinestore
                                txFileJSON=$(cat ${txFile} | jq .)
                                offlineJSON=$( jq ".transactions += [ { date: \"$(date -R)\",
                                                                        type: \"Withdrawal\",
                                                                        era: \"$(jq -r .protocol.era <<< ${offlineJSON})\",
                                                                        stakeAddr: \"${stakeAddr}\",
									stakingAddr: \"${stakingAddr}\",
									fromAddr: \"${fromAddr}\",
                                                                        sendFromAddr: \"${sendFromAddr}\",
                                                                        toAddr: \"${toAddr}\",
                                                                        sendToAddr: \"${sendToAddr}\",
                                                                        txJSON: ${txFileJSON} } ]" <<< ${offlineJSON})
                                #Write the new offileFile content
                                offlineJSON=$( jq ".history += [ { date: \"$(date -R)\", action: \"signed rewards withdrawal from '${stakeAddr}' to '${toAddr}', payment via '${fromAddr}'\" } ]" <<< ${offlineJSON})
                                offlineJSON=$( jq ".general += {offlineCLI: \"${versionCLI}\" }" <<< ${offlineJSON})
                                offlineJSON=$( jq ".general += {offlineNODE: \"${versionNODE}\" }" <<< ${offlineJSON})
                                echo "${offlineJSON}" > ${offlineFile}
                                #Readback the tx content and compare it to the current one
                                readback=$(cat ${offlineFile} | jq -r ".transactions[-1].txJSON")
                                if [[ "${txFileJSON}" == "${readback}" ]]; then
                                                        showOfflineFileInfo;
                                                        echo -e "\e[33mTransaction txJSON has been stored in the '$(basename ${offlineFile})'.\nYou can now transfer it to your online machine for execution.\e[0m\n";
                                                 else
                                                        echo -e "\e[35mERROR - Could not verify the written data in the '$(basename ${offlineFile})'. Retry again or generate a new '$(basename ${offlineFile})'.\e[0m\n";
                                fi

        fi

fi

echo -e "\e[0m\n"
