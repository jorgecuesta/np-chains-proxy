#!/bin/sh
#
# This script launches nginx and the NGINX Amplify Agent.
#
# Unless already baked in the image, a real API_KEY is required for the
# NGINX Amplify Agent to be able to connect to the backend.
#
# If AMPLIFY_IMAGENAME is set, the script will use it to generate
# the 'imagename' to put in the /etc/amplify-agent/agent.conf
#
# If several instances use the same imagename, the metrics will
# be aggregated into a single object in Amplify. Otherwise NGINX Amplify
# will create separate objects for monitoring (an object per instance).
#

# Variables
agent_conf_file="/etc/amplify-agent/agent.conf"
agent_log_file="/var/log/amplify-agent/agent.log"
nginx_status_conf="/etc/nginx/conf.d/stub_status.conf"
api_key=""
amplify_imagename=""

set -eu

ME=$(basename nginx)
LC_ALL=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin


touch /etc/nginx/nginx.conf 2>/dev/null || { echo "$ME: error: can not modify /etc/nginx/nginx.conf (read-only file system?)"; exit 0; }

ceildiv() {
  num=$1
  div=$2
  echo $(( (num + div - 1) / div ))
}

get_cpuset() {
  cpusetroot=$1
  cpusetfile=$2
  ncpu=0
  [ -f "$cpusetroot/$cpusetfile" ] || return 1
  for token in $( tr ',' ' ' < "$cpusetroot/$cpusetfile" ); do
    case "$token" in
      *-*)
        count=$( seq $(echo "$token" | tr '-' ' ') | wc -l )
        ncpu=$(( ncpu+count ))
        ;;
      *)
        ncpu=$(( ncpu+1 ))
        ;;
    esac
  done
  echo "$ncpu"
}

get_quota() {
  cpuroot=$1
  ncpu=0
  [ -f "$cpuroot/cpu.cfs_quota_us" ] || return 1
  [ -f "$cpuroot/cpu.cfs_period_us" ] || return 1
  cfs_quota=$( cat "$cpuroot/cpu.cfs_quota_us" )
  cfs_period=$( cat "$cpuroot/cpu.cfs_period_us" )
  [ "$cfs_quota" = "-1" ] && return 1
  [ "$cfs_period" = "0" ] && return 1
  ncpu=$( ceildiv "$cfs_quota" "$cfs_period" )
  [ "$ncpu" -gt 0 ] || return 1
  echo "$ncpu"
}

get_quota_v2() {
  cpuroot=$1
  ncpu=0
  [ -f "$cpuroot/cpu.max" ] || return 1
  cfs_quota=$( cut -d' ' -f 1 < "$cpuroot/cpu.max" )
  cfs_period=$( cut -d' ' -f 2 < "$cpuroot/cpu.max" )
  [ "$cfs_quota" = "max" ] && return 1
  [ "$cfs_period" = "0" ] && return 1
  ncpu=$( ceildiv "$cfs_quota" "$cfs_period" )
  [ "$ncpu" -gt 0 ] || return 1
  echo "$ncpu"
}

get_cgroup_v1_path() {
  needle=$1
  found=
  foundroot=
  mountpoint=

  [ -r "/proc/self/mountinfo" ] || return 1
  [ -r "/proc/self/cgroup" ] || return 1

  while IFS= read -r line; do
    case "$needle" in
      "cpuset")
        case "$line" in
          *cpuset*)
            found=$( echo "$line" | cut -d ' ' -f 4,5 )
            break
            ;;
        esac
        ;;
      "cpu")
        case "$line" in
          *cpuset*)
            ;;
          *cpu,cpuacct*|*cpuacct,cpu|*cpuacct*|*cpu*)
            found=$( echo "$line" | cut -d ' ' -f 4,5 )
            break
            ;;
        esac
    esac
  done << __EOF__
$( grep -F -- '- cgroup ' /proc/self/mountinfo )
__EOF__

  while IFS= read -r line; do
    controller=$( echo "$line" | cut -d: -f 2 )
    case "$needle" in
      "cpuset")
        case "$controller" in
          cpuset)
            mountpoint=$( echo "$line" | cut -d: -f 3 )
            break
            ;;
        esac
        ;;
      "cpu")
        case "$controller" in
          cpu,cpuacct|cpuacct,cpu|cpuacct|cpu)
            mountpoint=$( echo "$line" | cut -d: -f 3 )
            break
            ;;
        esac
        ;;
    esac
done << __EOF__
$( grep -F -- 'cpu' /proc/self/cgroup )
__EOF__

  case "${found%% *}" in
    "/")
      foundroot="${found##* }$mountpoint"
      ;;
    "$mountpoint")
      foundroot="${found##* }"
      ;;
  esac
  echo "$foundroot"
}

get_cgroup_v2_path() {
  found=
  foundroot=
  mountpoint=

  [ -r "/proc/self/mountinfo" ] || return 1
  [ -r "/proc/self/cgroup" ] || return 1

  while IFS= read -r line; do
    found=$( echo "$line" | cut -d ' ' -f 4,5 )
  done << __EOF__
$( grep -F -- '- cgroup2 ' /proc/self/mountinfo )
__EOF__

  while IFS= read -r line; do
    mountpoint=$( echo "$line" | cut -d: -f 3 )
done << __EOF__
$( grep -F -- '0::' /proc/self/cgroup )
__EOF__

  case "${found%% *}" in
    "")
      return 1
      ;;
    "/")
      foundroot="${found##* }$mountpoint"
      ;;
    "$mountpoint")
      foundroot="${found##* }"
      ;;
  esac
  echo "$foundroot"
}

ncpu_online=$( getconf _NPROCESSORS_ONLN )
ncpu_cpuset=
ncpu_quota=
ncpu_cpuset_v2=
ncpu_quota_v2=

cpuset=$( get_cgroup_v1_path "cpuset" ) && ncpu_cpuset=$( get_cpuset "$cpuset" "cpuset.effective_cpus" ) || ncpu_cpuset=$ncpu_online
cpu=$( get_cgroup_v1_path "cpu" ) && ncpu_quota=$( get_quota "$cpu" ) || ncpu_quota=$ncpu_online
cgroup_v2=$( get_cgroup_v2_path ) && ncpu_cpuset_v2=$( get_cpuset "$cgroup_v2" "cpuset.cpus.effective" ) || ncpu_cpuset_v2=$ncpu_online
cgroup_v2=$( get_cgroup_v2_path ) && ncpu_quota_v2=$( get_quota_v2 "$cgroup_v2" ) || ncpu_quota_v2=$ncpu_online

ncpu=$( printf "%s\n%s\n%s\n%s\n%s\n" \
               "$ncpu_online" \
               "$ncpu_cpuset" \
               "$ncpu_quota" \
               "$ncpu_cpuset_v2" \
               "$ncpu_quota_v2" \
               | sort -n \
               | head -n 1 )

cp /etc/nginx/nginx.conf ~/nginx.conf

sed -i.bak -r 's/^(worker_processes)(.*)$/# Commented out by '"$ME"' on '"$(date)"'\n#\1\2\n\1 '"$ncpu"';/' ~/nginx.conf

cp -f ~/nginx.conf /etc/nginx/nginx.conf

auto_envsubst() {
  local template_dir="${NGINX_ENVSUBST_TEMPLATE_DIR:-/etc/nginx/templates}"
  local suffix="${NGINX_ENVSUBST_TEMPLATE_SUFFIX:-.template}"
  local output_dir="${NGINX_ENVSUBST_OUTPUT_DIR:-/etc/nginx/conf.d}"

  local template defined_envs relative_path output_path subdir
  defined_envs=$(printf '${%s} ' $(env | cut -d= -f1))
  [ -d "$template_dir" ] || return 0
  if [ ! -w "$output_dir" ]; then
    echo "$ME: ERROR: $template_dir exists, but $output_dir is not writable"
    return 0
  fi
  find "$template_dir" -follow -type f -name "*$suffix" -print | while read -r template; do
    relative_path="${template#$template_dir/}"
    output_path="$output_dir/${relative_path%$suffix}"
    subdir=$(dirname "$relative_path")
    # create a subdirectory where the template file exists
    mkdir -p "$output_dir/$subdir"
    echo "$ME: Running envsubst on $template to $output_path"
    envsubst "$defined_envs" < "$template" > "$output_path"
  done
}

auto_envsubst

chown nginx /etc/nginx/nginx.conf
chmod 644 /etc/nginx/nginx.conf

# Launch nginx
echo "starting nginx ..."
nginx -g "daemon off;" &

nginx_pid=$!

test -n "${API_KEY}" && \
    api_key=${API_KEY}

test -n "${AMPLIFY_IMAGENAME}" && \
    amplify_imagename=${AMPLIFY_IMAGENAME}

if [ -n "${api_key}" -o -n "${amplify_imagename}" ]; then
    echo "updating ${agent_conf_file} ..."

    if [ ! -f "${agent_conf_file}" ]; then
	test -f "${agent_conf_file}.default" && \
	cp -p "${agent_conf_file}.default" "${agent_conf_file}" || \
	{ echo "no ${agent_conf_file}.default found! exiting."; exit 1; }
    fi

    test -n "${api_key}" && \
    echo " ---> using api_key = ${api_key}" && \
    sh -c "sed -i.old -e 's/api_key.*$/api_key = $api_key/' \
	${agent_conf_file}"

    test -n "${amplify_imagename}" && \
    echo " ---> using imagename = ${amplify_imagename}" && \
    sh -c "sed -i.old -e 's/imagename.*$/imagename = $amplify_imagename/' \
	${agent_conf_file}"

    test -f "${agent_conf_file}" && \
    chmod 644 ${agent_conf_file} && \
    chown nginx ${agent_conf_file} > /dev/null 2>&1

    test -f "${nginx_status_conf}" && \
    chmod 644 ${nginx_status_conf} && \
    chown nginx ${nginx_status_conf} > /dev/null 2>&1
fi

if ! grep '^api_key.*=[ ]*[[:alnum:]].*' ${agent_conf_file} > /dev/null 2>&1; then
    echo "no api_key found in ${agent_conf_file}! exiting."
fi

echo "starting amplify-agent ..."
service amplify-agent start > /dev/null 2>&1 < /dev/null

if [ $? != 0 ]; then
    echo "couldn't start the agent, please check ${agent_log_file}"
    exit 1
fi

wait ${nginx_pid}

echo "nginx master process has stopped, exiting."
