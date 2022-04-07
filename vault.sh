#!/bin/bash

VAULT_REGEXP="(.*)=?vault:?([^:]+)?:([^#]*?)#([^:]*):?(.+)?"
CERT_REGEXP="-----BEGIN (CERTIFICATE|PRIVATE KEY)-----.+-----END (CERTIFICATE|PRIVATE KEY)-----"
export PWD_DEFAULT_LENGTH=16;
##########################################################################################
# vault login with approle - returns token
# Globals:
#   VAULT_ADDR - url for vault required
#   VAULT_ROLE_ID & VAULT_SECRET_ID - vault approle
#   VAULT_TOKEN - a plain vault topken (if not approle provided)
# Arguments:
#   None
# Returns:
#   None
##########################################################################################
function vault_login() {
    # quit fast from function if already logged
    if [[ -n $VAULT_TOKEN ]]; then
      return
    fi
    if [[ -z $VAULT_ADDR ]]; then
        echo "No Vault address found" >/dev/stderr
        false
    fi
    if [[ "$VAULT_ROLE_ID" != "" ]] && [[ "$VAULT_SECRET_ID" != "" ]]; then
        # login with approle
        declare -x VAULT_TOKEN
        VAULT_TOKEN=$(vault write auth/approle/login role_id="${VAULT_ROLE_ID}" secret_id="${VAULT_SECRET_ID}" |grep "token "|awk '{print $2}')
    fi
    if [[ -z $VAULT_TOKEN  ]]; then
        # no valid login method
        echo "No Vault login credentials found" >/dev/stderr
        false
    fi
}
##########################################################################################
# Generate a algorithmed password of the passed value.
# Globals:
#   None
# Arguments:
#   $1 - method of encryption (bc -> bcrypt or ht[username] -> htpasswd)
#   $2 string to algorithm
# Returns:
#   b-crypted string
##########################################################################################
function encrypt() {
  case $1 in
    bc)
      bcrypt $2
    ;;
    ht*)
      htpasswd -nb "${1/ht_/}" "${2}"
    ;;
    fn)
      fernet
    ;;
    *)
      false
    ;;
  esac
}
##########################################################################################
# Generate a random password with alphanumeric characters.
# Globals:
#   None
# Arguments:
#   $1 - desired length (mandatory) or PWD_DEFAULT_LENGTH will be applied
# Returns:
#   None - password is output to STDOUT
##########################################################################################
function generateRandomPasswd() {
    head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c ${1:-$PWD_DEFAULT_LENGTH} ;
}
##########################################################################################
# Get a single value from vault. If a crt is saved in that value, it will try to detect
# by looking at the BEGIN CERTIFICATE string and if found, will substitute the
# Arguments:
#   $1 = path
#   $2 = value
# Returns:
#   None: outputs the field to STDOUT
##########################################################################################
function vault_read() {
    value=$(vault read --field=$2 $1 2> /dev/null;)
    if [[ -z ${value} ]];then
        echo "Vault value at \"$1#$2\" not found" > /dev/stderr
        return 12
    fi
    echo "${value}"
}
##########################################################################################
# generate a password of length passed by parameter.
# If second parameter is not empty, it will generate a hash with the algorith passed
# for that password
# Arguments:
#   $1 = length (mandatory)
#   $2 = algorithm (optional) can be bc -> bcrypt ht -> htpasswd, if empty it will be a random
#        string using OS random functionality
# Returns:
#   None: outputs the password generated, if arg 2 is present, it will add an space and the
#   algorithmed password after the password.
##########################################################################################
function generatepwd() {
    length_or_value=$1
    algorithm=$2
    if [[ "${length_or_value}" =~ ^([1-9][0-9]*)$ ]];then
        if [[ -n $algorithm ]];then
          before_encrypt=$(generateRandomPasswd ${BASH_REMATCH[1]})
          value=$(encrypt $algorithm $before_encrypt)
          echo "${value} ${before_encrypt}"
        else
          value="$(generateRandomPasswd ${BASH_REMATCH[1]})"
          echo "${value}"
        fi
    else
        echo "${length_or_value}"
    fi
}
##########################################################################################
# Get a single value from vault, if param length found, generate a new one and write it
# to vault as an object (json object)
# Arguments:
#   $1 = path
#   $2 = key
#   $3 = value/length. If expressed as number, it will be considered as the length
#   of the password to generate (optional), if empty or equals 0 return what is
#   found in path + key from Vault. Else if expressed as no number will be used as a value to
#   write to vault.
# length.
# Returns:
#   None: outputs the field to STDOUT
##########################################################################################
function vault_read_or_generate() {
    path=$1
    key=$2
    length_or_value=$3
    algorithm=$4
    # if length_or_value informed and not equal to 0 (readonly mode) then generate
    # a value in case of number greater than 0 or use the length_or_value like a fixed value
    if [[ -n ${length_or_value} ]] && [[ ! "${length_or_value}" == "0" ]];then
        # search if there is an object with that path already in vault
        jsonsecret=$(vault read ${path} --format=json 2>/dev/null | jq '.data' 2>/dev/null)
        # rest of reads will be done to this jsonsecret object to reduce vault calls
        value=$(jq -r ".\"${key}\" // empty" <<< ${jsonsecret})
        if [[ -z $value ]];then
          value="$(generatepwd ${length_or_value} ${algorithm})";
        else
          bc=$(jq -r ".\"${key}_before_encrypt\" // empty" <<<  ${jsonsecret})
          if [[ -n $bc ]];then value="${value} ${bc}";fi
        fi
        arr=($value)
        value=${arr[0]}
        before_encrypt=${arr[1]}
        if [[ -n "${jsonsecret}"  ]];then
            # if found that object, add this new field and password to it
            var2="{ \"$key\": \"$value\" }"
            var3=""
            if [[ -n $algorithm ]];then var3="{ \"${key}_before_encrypt\": \"$before_encrypt\" }";fi
            v=$(echo "${jsonsecret}" "${var2}" "${var3}" | jq -s add)
        else
            # if not, just create a new object with this key and password
            v="{ \"$key\": \"$value\" }"
            if [[ -n $algorithm ]];then
              var3="{ \"${key}_before_encrypt\": \"$before_encrypt\" }";
              v=$(echo "$v" "$var3" | jq -s add);
            fi
        fi
        if [[ -z ${DRY_RUN} ]];then
            jq <<< "$v" | vault write ${path} - >/dev/null
        fi
        echo "${value}"
    else
        vault_read ${path} ${key} || false
    fi
}

##########################################################################################
# parse provided string, searching for a format like:
#   - "variablename=vault:/path_in_vault#key" path to vault secret and name of the secret
#   - "variablename=vault:/path_in_vault#key:number" as the first value plus a length desired
#       of password generation if not found in vault.
# In case it's found, use the information to search for a key in vault by calling
#   vault_read_or_generate function
# In case not found, echo the input string
# Globals:
#   VAULT_REGEXP - regular expression to parse the line
# Argument:
#   $1 - line to parse
# Returns:
#   None, output to STDOUT line parsed
##########################################################################################
function parseAndFillVaultUri() {
    line=$1
    if [[ ${line} =~ $VAULT_REGEXP ]]; then
        printf "%s" "$(vault_read_or_generate ${BASH_REMATCH[3]} ${BASH_REMATCH[4]} ${BASH_REMATCH[5]} ${BASH_REMATCH[2]})"
    else
        echo -n "$line"
    fi
}
