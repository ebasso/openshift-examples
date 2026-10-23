#!/bin/bash

# ============================================================
# OpenShift Node & Chrony / Clock Health Check
# Target Alert: NodeClockNotSynchronising
# ============================================================

LOG_FILE="node-clock-check.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "============================================================"
echo " OPENSHIFT NODE & CLOCK SYNCHRONIZATION CHECK"
echo " Date: $(date '+%Y-%m-%d %H:%M:%S')"
echo " Log:  $LOG_FILE"
echo "============================================================"

# Check that the oc command is available and authenticated
if ! command -v oc &> /dev/null; then
  echo "[ERROR] The 'oc' command was not found in PATH."
  exit 1
fi

if ! oc whoami &> /dev/null; then
  echo "[ERROR] Unable to authenticate to OpenShift. Check your login (oc login)."
  exit 1
fi

echo ""
echo ">>> 1. OVERALL NODE STATUS"
echo "------------------------------------------------------------"
oc get nodes -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,REASON:.status.conditions[-1].reason,ROLES:.metadata.labels."node-role\.kubernetes\.io/master",VERSION:.status.nodeInfo.kubeletVersion

echo ""
echo ">>> 2. CHECKING ACTIVE ALERTS (NodeClockNotSynchronising)"
echo "------------------------------------------------------------"
ACTIVE_ALERTS=$(oc -n openshift-monitoring exec prometheus-k8s-0 -c prometheus -- \
  promtool query instant http://localhost:9090 'ALERTS{alertname="NodeClockNotSynchronising",alertstate="firing"}' 2>/dev/null || true)

if [ -n "$ACTIVE_ALERTS" ]; then
  echo "$ACTIVE_ALERTS"
else
  echo "  (Unable to query Prometheus directly via pod, or no active alerts returned by the instant query)"
fi

echo ""
echo ">>> 3. CHRONY / NTP SERVICE CHECK ON EACH NODE (via oc debug)"
echo "------------------------------------------------------------"
NODES=$(oc get nodes -o jsonpath='{.items[*].metadata.name}')

for NODE in $NODES; do
  echo ""
  echo "============================================================"
  echo " NODE: $NODE"
  echo "============================================================"

  # Get local date, chrony tracking and NTP sources via chroot /host
  oc debug node/"$NODE" --to-namespace=default --quiet -- chroot /host /bin/bash -c '
    echo "--- [LOCAL DATE AND TIME ON HOST] ---"
    date "+%Y-%m-%d %H:%M:%S %Z (Epoch: %s)"
    
    echo ""
    echo "--- [CHRONY TRACKING] ---"
    if command -v chronyc &>/dev/null; then
      chronyc tracking 2>&1 || echo "Error running chronyc tracking"
      echo ""
      echo "--- [CHRONY SOURCES] ---"
      chronyc sources -v 2>&1 || echo "Error running chronyc sources"
      echo ""
      echo "--- [CHRONY SOURCESTATS] ---"
      chronyc sourcestats 2>&1 || echo "Error running chronyc sourcestats"
    elif command -v timedatectl &>/dev/null; then
      timedatectl status 2>&1
    else
      echo "chronyc/timedatectl not found on host."
    fi

    echo ""
    echo "--- [SYSTEMD CHRONYD SERVICE STATUS] ---"
    systemctl status chronyd --no-pager 2>&1 | head -n 15 || true
  ' 2>/dev/null || echo "  [ERROR] Failed to run oc debug on node $NODE"

done

echo ""
echo "============================================================"
echo " SUMMARY & REMEDIATION RECOMMENDATIONS"
echo "============================================================"
echo "If any node shows 'Leap status: Not synchronised' or 'Reference ID: 00000000':"
echo " 1. Check that the NTP servers defined in MachineConfig / chrony.conf are reachable over the network (UDP port 123)."
echo " 2. Check applied MachineConfigs with 'oc get mc | grep chrony'."
echo " 3. Force resynchronization on the node: 'chronyc makestep' or 'systemctl restart chronyd'."
echo "============================================================"
