#!/bin/bash
# 通用 k3s 一键部署脚本（交互式菜单）
#
# 适用场景：
# - 单控制面 / 多控制面（embedded etcd，支持 cluster-init + join）
# - 混合架构（amd64/arm64）也可用，但请确保业务镜像是 multi-arch
# - 可选：把 Ingress 控制器（k3s 默认 Traefik）固定到“入口节点”（通过标签选择）
# - 可选：NFS 存储服务器 + NFS 动态 StorageClass（适合 RWX/共享文件；DB 更建议 local-path）
#
# 用法：在每台机器上分别执行本脚本，按菜单选择角色
#   sudo bash k3s_setup.sh
#
# 重要提示（尤其是多控制面）：
# - embedded etcd 对网络延迟/抖动敏感，建议控制面节点放在同地域/低延迟网络；
#   跨地域仅建议用于学习，遇到控制面抖动属于正常现象。

set -e
set -u

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "请使用 root 运行此脚本，例如：sudo bash k3s_setup.sh"
        exit 1
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

random_token() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || echo "defaulttokendefaulttokendefaultto"
}

ask_non_empty() {
    local prompt="$1"
    local val=""
    while true; do
        read -rp "${prompt}" val
        if [ -n "${val}" ]; then
            printf "%s" "${val}"
            return 0
        fi
        echo "输入不能为空，请重新输入。"
    done
}

ask_with_default() {
    local prompt="$1"
    local default_val="$2"
    local val=""
    read -rp "${prompt}" val
    if [ -z "${val}" ]; then
        printf "%s" "${default_val}"
    else
        printf "%s" "${val}"
    fi
}

ask_yes_no() {
    # 返回 0 表示 yes，1 表示 no
    local prompt="$1"
    local default_choice="$2"
    local raw=""

    while true; do
        if [ "${default_choice}" = "y" ]; then
            read -rp "${prompt} [Y/n]: " raw
            raw=${raw:-y}
        else
            read -rp "${prompt} [y/N]: " raw
            raw=${raw:-n}
        fi

        case "${raw}" in
            y|Y) return 0 ;;
            n|N) return 1 ;;
            *) echo "请输入 y 或 n。" ;;
        esac
    done
}

ask_labels() {
    local raw labels=""
    read -rp "可选：为节点添加标签（用逗号或空格分隔，例如 region=hk,role=ingress，直接回车跳过）: " raw
    if [ -n "${raw}" ]; then
        IFS=', ' read -ra arr <<<"${raw}"
        for label in "${arr[@]}"; do
            if [ -n "${label}" ]; then
                labels+=" --node-label ${label}"
            fi
        done
    fi
    printf "%s" "${labels}"
}

ask_taints() {
    local raw taints=""
    read -rp "可选：为节点添加污点（用逗号或空格分隔，例如 dedicated=ingress:NoSchedule，直接回车跳过）: " raw
    if [ -n "${raw}" ]; then
        IFS=', ' read -ra arr <<<"${raw}"
        for taint in "${arr[@]}"; do
            if [ -n "${taint}" ]; then
                taints+=" --node-taint ${taint}"
            fi
        done
    fi
    printf "%s" "${taints}"
}

choose_k3s_mirror() {
    if ask_yes_no "是否使用国内 k3s 安装镜像（INSTALL_K3S_MIRROR=cn）？" "n"; then
        export INSTALL_K3S_MIRROR=cn
        echo "已启用国内 k3s 安装镜像。"
    else
        unset INSTALL_K3S_MIRROR >/dev/null 2>&1 || true
        echo "使用官方默认镜像。"
    fi
}

prepare_common() {
    echo "==== [通用初始化] 开始 ===="

    echo "[1/4] 关闭 swap..."
    swapoff -a || true
    sed -ri 's/^\s*([^#]\S*\s+\S*\s+swap\s+\S+.*)$/# \1/' /etc/fstab || true

    echo "[2/4] 安装基础工具（curl、nfs-common、vim、git）..."
    if command_exists apt-get; then
        apt-get update -y
        apt-get install -y curl nfs-common vim git
    else
        echo "未检测到 apt-get，请自行安装 curl、nfs 客户端等工具。"
    fi

    echo "[3/4] 启用桥接转发..."
    cat >/etc/modules-load.d/k3s.conf <<'EOF'
br_netfilter
EOF
    modprobe br_netfilter >/dev/null 2>&1 || true
    cat >/etc/sysctl.d/99-k3s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
    sysctl --system >/dev/null

    echo "[4/4] 通用初始化完成。若刚修改内核模块/参数，建议重启后再继续。"
    echo "==== [通用初始化] 结束 ===="
}

setup_nfs_server() {
    echo "==== [NFS 存储服务器配置] 开始 ===="

    local nfs_dir nfs_net export_opts
    nfs_dir=$(ask_with_default "请输入 NFS 导出目录 [默认 /data/k3s]: " "/data/k3s")
    nfs_net=$(ask_non_empty "请输入允许访问的内网网段（CIDR，例如 10.10.0.0/16）: ")

    export_opts="rw,sync,no_subtree_check"
    if ask_yes_no "是否关闭 root_squash（no_root_squash，更省心但更不安全）？" "y"; then
        export_opts+=",no_root_squash"
    else
        export_opts+=",root_squash"
    fi

    if command_exists apt-get; then
        echo "[1/4] 安装 nfs-kernel-server..."
        apt-get update -y
        apt-get install -y nfs-kernel-server
    else
        echo "未检测到 apt-get，请确保已手动安装 nfs-kernel-server。"
    fi

    echo "[2/4] 创建目录 ${nfs_dir} ..."
    mkdir -p "${nfs_dir}"
    chown nobody:nogroup "${nfs_dir}" || true
    chmod 0777 "${nfs_dir}"

    echo "[3/4] 配置 /etc/exports..."
    sed -i "\|${nfs_dir}|d" /etc/exports || true
    cat >>/etc/exports <<EOF
${nfs_dir} ${nfs_net}(${export_opts})
EOF
    exportfs -ra

    echo "[4/4] 启动 NFS 服务..."
    systemctl enable nfs-server >/dev/null 2>&1 || systemctl enable nfs-kernel-server >/dev/null 2>&1 || true
    systemctl restart nfs-server >/dev/null 2>&1 || systemctl restart nfs-kernel-server >/dev/null 2>&1 || true

    echo "NFS 已就绪：导出目录=${nfs_dir}，允许网段=${nfs_net}"
    echo "==== [NFS 存储服务器配置] 结束 ===="
}

install_k3s_server_first() {
    echo "==== [安装 k3s server（首个控制面）] 开始 ===="

    local node_ip node_name overlay_iface token label_args taint_args disable_args extra_args install_exec
    node_ip=$(ask_non_empty "请输入本机用于集群通信的内网 IP（例如 easytier 的 IP）: ")
    overlay_iface=$(ask_with_default "可选：请输入 overlay 网卡名（例如 easytier0；留空则不指定 --flannel-iface）: " "")
    node_name=$(ask_with_default "设置节点名称（node-name）[默认使用主机名]: " "$(hostname)")

    read -rp "请输入集群 TOKEN（回车自动生成）: " token
    token=${token:-$(random_token)}

    choose_k3s_mirror

    label_args=$(ask_labels)
    taint_args=$(ask_taints)

    disable_args=""
    if ask_yes_no "是否禁用 k3s servicelb（常见做法：入口用 Ingress/NodePort，避免占用 80/443）？" "y"; then
        disable_args+=" --disable servicelb"
    fi

    install_exec="server \
        --write-kubeconfig-mode 644 \
        --node-name ${node_name} \
        --node-ip ${node_ip} \
        --advertise-address ${node_ip} \
        --tls-san ${node_ip}${label_args}${taint_args}${disable_args}"

    if ask_yes_no "是否启用 embedded etcd（多控制面 HA，首个节点将使用 --cluster-init）？" "n"; then
        echo "提示：embedded etcd 对延迟/抖动敏感，控制面节点建议同地域/低延迟。"
        install_exec+=" --cluster-init"
    fi

    if [ -n "${overlay_iface}" ]; then
        install_exec+=" --flannel-iface ${overlay_iface}"
    fi

    extra_args=$(ask_with_default "可选：补充额外 server 参数（例如 --disable traefik；留空跳过）: " "")
    if [ -n "${extra_args}" ]; then
        install_exec+=" ${extra_args}"
    fi

    export K3S_TOKEN="${token}"
    export INSTALL_K3S_EXEC="${install_exec}"

    echo
    echo "即将安装 k3s server，确认信息："
    echo "  内网 IP   : ${node_ip}"
    echo "  网卡      : ${overlay_iface:-<未指定>}"
    echo "  节点名    : ${node_name}"
    echo "  TOKEN     : ${token}"
    echo "  镜像源    : ${INSTALL_K3S_MIRROR:-官方默认}"
    echo "  INSTALL_K3S_EXEC: ${INSTALL_K3S_EXEC}"
    read -rp "按回车继续，Ctrl+C 取消..." _

    curl -sfL https://get.k3s.io | sh -

    echo
    echo "安装完成："
    echo "  查看节点: sudo kubectl get node"
    echo "  kubeconfig: /etc/rancher/k3s/k3s.yaml"
    echo "  TOKEN（请保存）: ${token}"
    echo "==== [安装 k3s server（首个控制面）] 结束 ===="
}

install_k3s_server_join() {
    echo "==== [安装 k3s server（加入已有控制面）] 开始 ===="

    local server_ip node_ip node_name overlay_iface token label_args taint_args disable_args extra_args install_exec
    server_ip=$(ask_non_empty "请输入已存在的 server 内网 IP（用于加入控制面）: ")
    node_ip=$(ask_non_empty "请输入本机用于集群通信的内网 IP（例如 easytier 的 IP）: ")
    overlay_iface=$(ask_with_default "可选：请输入 overlay 网卡名（例如 easytier0；留空则不指定 --flannel-iface）: " "")
    node_name=$(ask_with_default "设置节点名称（node-name）[默认使用主机名]: " "$(hostname)")
    token=$(ask_non_empty "请输入集群 TOKEN（与首个 server 相同）: ")

    choose_k3s_mirror

    label_args=$(ask_labels)
    taint_args=$(ask_taints)

    disable_args=""
    if ask_yes_no "是否禁用 servicelb（建议与集群保持一致）？" "y"; then
        disable_args+=" --disable servicelb"
    fi

    export K3S_URL="https://${server_ip}:6443"
    export K3S_TOKEN="${token}"

    install_exec="server \
        --node-name ${node_name} \
        --node-ip ${node_ip} \
        --advertise-address ${node_ip} \
        --tls-san ${node_ip}${label_args}${taint_args}${disable_args}"

    if [ -n "${overlay_iface}" ]; then
        install_exec+=" --flannel-iface ${overlay_iface}"
    fi

    extra_args=$(ask_with_default "可选：补充额外 server 参数（留空跳过）: " "")
    if [ -n "${extra_args}" ]; then
        install_exec+=" ${extra_args}"
    fi

    export INSTALL_K3S_EXEC="${install_exec}"

    echo
    echo "即将加入控制面（k3s server），确认信息："
    echo "  目标 server: ${server_ip}"
    echo "  本机 IP   : ${node_ip}"
    echo "  网卡      : ${overlay_iface:-<未指定>}"
    echo "  节点名    : ${node_name}"
    echo "  镜像源    : ${INSTALL_K3S_MIRROR:-官方默认}"
    echo "  K3S_URL   : ${K3S_URL}"
    echo "  INSTALL_K3S_EXEC: ${INSTALL_K3S_EXEC}"
    echo "提示：加入控制面要求集群处于 HA（embedded etcd / external datastore）模式。"
    read -rp "按回车继续，Ctrl+C 取消..." _

    curl -sfL https://get.k3s.io | sh -

    echo "安装完成，请在任一 server 上执行：sudo kubectl get node"
    echo "==== [安装 k3s server（加入已有控制面）] 结束 ===="
}

install_k3s_agent() {
    echo "==== [安装 k3s agent] 开始 ===="

    local server_ip node_ip node_name overlay_iface token label_args taint_args extra_args install_exec
    server_ip=$(ask_non_empty "请输入任一 server 的内网 IP（agent 将连接它加入集群）: ")
    node_ip=$(ask_non_empty "请输入本机用于集群通信的内网 IP（例如 easytier 的 IP）: ")
    overlay_iface=$(ask_with_default "可选：请输入 overlay 网卡名（例如 easytier0；留空则不指定 --flannel-iface）: " "")
    node_name=$(ask_with_default "设置节点名称（node-name）[默认使用主机名]: " "$(hostname)")
    token=$(ask_non_empty "请输入集群 TOKEN: ")

    choose_k3s_mirror

    label_args=""
    taint_args=""
    if ask_yes_no "是否将该节点标记为 Ingress 入口节点（自动加标签 ingress=true）？" "n"; then
        label_args+=" --node-label ingress=true"
        if ask_yes_no "是否为入口节点添加污点 dedicated=ingress:NoSchedule（避免普通业务挤占入口）？" "y"; then
            taint_args+=" --node-taint dedicated=ingress:NoSchedule"
        fi
    fi

    label_args+=$(ask_labels)
    taint_args+=$(ask_taints)

    export K3S_URL="https://${server_ip}:6443"
    export K3S_TOKEN="${token}"

    install_exec="agent --node-name ${node_name} --node-ip ${node_ip}${label_args}${taint_args}"
    if [ -n "${overlay_iface}" ]; then
        install_exec+=" --flannel-iface ${overlay_iface}"
    fi

    extra_args=$(ask_with_default "可选：补充额外 agent 参数（留空跳过）: " "")
    if [ -n "${extra_args}" ]; then
        install_exec+=" ${extra_args}"
    fi

    export INSTALL_K3S_EXEC="${install_exec}"

    echo
    echo "即将安装 k3s agent，确认信息："
    echo "  server IP : ${server_ip}"
    echo "  本机 IP   : ${node_ip}"
    echo "  网卡      : ${overlay_iface:-<未指定>}"
    echo "  节点名    : ${node_name}"
    echo "  镜像源    : ${INSTALL_K3S_MIRROR:-官方默认}"
    echo "  K3S_URL   : ${K3S_URL}"
    echo "  INSTALL_K3S_EXEC: ${INSTALL_K3S_EXEC}"
    read -rp "按回车继续，Ctrl+C 取消..." _

    curl -sfL https://get.k3s.io | sh -

    echo "安装完成，请在任一 server 上执行：sudo kubectl get node"
    echo "==== [安装 k3s agent] 结束 ===="
}

ensure_kubectl_ready() {
    if ! command_exists kubectl; then
        echo "未检测到 kubectl。请在 k3s server 上执行本步骤，或安装 kubectl 后再试。"
        return 1
    fi

    export KUBECONFIG=${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}
    if [ ! -f "${KUBECONFIG}" ]; then
        echo "未找到 kubeconfig：${KUBECONFIG}"
        echo "请确认你在 k3s server 上执行，或手动导出 KUBECONFIG。"
        return 1
    fi

    return 0
}

configure_traefik_for_ingress_nodes() {
    echo "==== [配置 Traefik：固定到入口节点 + 可选 NodePort] 开始 ===="
    ensure_kubectl_ready || return 1

    local label_key label_value service_mode nodeport_http nodeport_https add_toleration config_path
    label_key=$(ask_with_default "入口节点标签 Key [默认 ingress]: " "ingress")
    label_value=$(ask_with_default "入口节点标签 Value [默认 true]: " "true")

    echo
    echo "Ingress 暴露方式建议："
    echo "  - NodePort：不占用 80/443，适合前置 Nginx/Caddy 做反代（推荐）"
    echo "  - LoadBalancer：需要 servicelb 或云厂商 LB，可能占用 80/443"
    if ask_yes_no "选择 NodePort 模式（推荐）？" "y"; then
        service_mode="NodePort"
        nodeport_http=$(ask_with_default "HTTP NodePort [默认 30080]: " "30080")
        nodeport_https=$(ask_with_default "HTTPS NodePort [默认 30443]: " "30443")
    else
        service_mode="LoadBalancer"
        nodeport_http=""
        nodeport_https=""
    fi

    add_toleration="false"
    if ask_yes_no "是否为 Traefik 添加 dedicated=ingress:NoSchedule 的容忍（入口节点常用污点）？" "y"; then
        add_toleration="true"
    fi

    config_path="/var/lib/rancher/k3s/server/manifests/traefik-custom-config.yaml"
    mkdir -p "$(dirname "${config_path}")"

    if [ "${service_mode}" = "NodePort" ]; then
        if [ "${add_toleration}" = "true" ]; then
            cat >"${config_path}" <<EOF
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
    name: traefik
    namespace: kube-system
spec:
    valuesContent: |-
        deployment:
            nodeSelector:
                ${label_key}: "${label_value}"
            tolerations:
                - key: "dedicated"
                  operator: "Equal"
                  value: "ingress"
                  effect: "NoSchedule"
        # NodePort：避免占用 80/443，便于前置反代
        service:
            type: NodePort
            spec:
                externalTrafficPolicy: Local
        ports:
            web:
                nodePort: ${nodeport_http}
            websecure:
                nodePort: ${nodeport_https}
EOF
        else
            cat >"${config_path}" <<EOF
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
    name: traefik
    namespace: kube-system
spec:
    valuesContent: |-
        deployment:
            nodeSelector:
                ${label_key}: "${label_value}"
        # NodePort：避免占用 80/443，便于前置反代
        service:
            type: NodePort
            spec:
                externalTrafficPolicy: Local
        ports:
            web:
                nodePort: ${nodeport_http}
            websecure:
                nodePort: ${nodeport_https}
EOF
        fi
    else
        if [ "${add_toleration}" = "true" ]; then
            cat >"${config_path}" <<EOF
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
    name: traefik
    namespace: kube-system
spec:
    valuesContent: |-
        deployment:
            nodeSelector:
                ${label_key}: "${label_value}"
            tolerations:
                - key: "dedicated"
                  operator: "Equal"
                  value: "ingress"
                  effect: "NoSchedule"
EOF
        else
            cat >"${config_path}" <<EOF
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
    name: traefik
    namespace: kube-system
spec:
    valuesContent: |-
        deployment:
            nodeSelector:
                ${label_key}: "${label_value}"
EOF
        fi
    fi

    echo "已写入配置：${config_path}"
    echo "正在应用配置（可能触发 traefik 自动重部署）..."
    kubectl apply -f "${config_path}" >/dev/null

    echo "等待 traefik 重新部署（可能需要 10~60 秒）..."
    kubectl -n kube-system rollout status deploy/traefik --timeout=180s >/dev/null 2>&1 || true

    echo "==== traefik Pod 分布 ===="
    kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik -o wide || true
    echo
    echo "==== traefik Service 信息 ===="
    kubectl -n kube-system get svc traefik -o wide || true

    if [ "${service_mode}" = "NodePort" ]; then
        echo
        echo "提示：你可以让前置 Nginx/Caddy 继续监听 80/443，然后按域名反代到："
        echo "  - http  -> 入口节点IP:${nodeport_http}"
        echo "  - https -> 入口节点IP:${nodeport_https}"
    fi

    echo "==== [配置 Traefik：固定到入口节点 + 可选 NodePort] 结束 ===="
}

deploy_nfs_dynamic_storage() {
    echo "==== [部署 NFS 动态 StorageClass] 开始 ===="
    ensure_kubectl_ready || return 1

    local nfs_server nfs_path sc_name set_default tmp_yaml
    nfs_server=$(ask_non_empty "请输入 NFS 服务器内网 IP: ")
    nfs_path=$(ask_with_default "请输入 NFS 导出路径 [默认 /data/k3s]: " "/data/k3s")
    sc_name=$(ask_with_default "StorageClass 名称 [默认 nfs-rwx]: " "nfs-rwx")

    echo
    echo "建议："
    echo "  - NFS 动态供给适合共享文件/RWX/练习；"
    echo "  - 数据库更推荐 local-path（RWO + 固定节点），避免 NFS 跨网延迟与一致性风险。"

    set_default="false"
    if ask_yes_no "是否把 ${sc_name} 设为默认 StorageClass？（通常不建议，默认否）" "n"; then
        set_default="true"
    fi

    tmp_yaml="/tmp/k3s-nfs-provisioner.yaml"
    cat >"${tmp_yaml}" <<EOF
apiVersion: v1
kind: Namespace
metadata:
    name: nfs-system
---
apiVersion: v1
kind: ServiceAccount
metadata:
    name: nfs-provisioner
    namespace: nfs-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
    name: nfs-provisioner-runner
rules:
    - apiGroups: [""]
      resources: ["persistentvolumes"]
      verbs: ["get", "list", "watch", "create", "delete"]
    - apiGroups: [""]
      resources: ["persistentvolumeclaims"]
      verbs: ["get", "list", "watch", "update"]
    - apiGroups: [""]
      resources: ["events"]
      verbs: ["create", "update", "patch"]
    - apiGroups: ["storage.k8s.io"]
      resources: ["storageclasses"]
      verbs: ["get", "list", "watch"]
    - apiGroups: [""]
      resources: ["services", "endpoints"]
      verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
    name: run-nfs-provisioner
roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: ClusterRole
    name: nfs-provisioner-runner
subjects:
    - kind: ServiceAccount
      name: nfs-provisioner
      namespace: nfs-system
---
apiVersion: apps/v1
kind: Deployment
metadata:
    name: nfs-provisioner
    namespace: nfs-system
spec:
    replicas: 1
    strategy:
        type: Recreate
    selector:
        matchLabels:
            app: nfs-provisioner
    template:
        metadata:
            labels:
                app: nfs-provisioner
        spec:
            serviceAccountName: nfs-provisioner
            containers:
                - name: nfs-provisioner
                  image: registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2
                  env:
                      - name: PROVISIONER_NAME
                        value: nfs-system/nfs-provisioner
                      - name: NFS_SERVER
                        value: ${nfs_server}
                      - name: NFS_PATH
                        value: ${nfs_path}
                  volumeMounts:
                      - name: nfs-root
                        mountPath: /persistentvolumes
            volumes:
                - name: nfs-root
                  nfs:
                      server: ${nfs_server}
                      path: ${nfs_path}
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
    name: ${sc_name}
    annotations:
        storageclass.kubernetes.io/is-default-class: "false"
provisioner: nfs-system/nfs-provisioner
parameters:
    archiveOnDelete: "true"
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
EOF

    echo "正在部署 NFS 动态 StorageClass：${sc_name}"
    kubectl apply -f "${tmp_yaml}" >/dev/null
    kubectl -n nfs-system rollout status deploy/nfs-provisioner --timeout=180s >/dev/null 2>&1 || true

    if [ "${set_default}" = "true" ]; then
        echo "正在设置默认 StorageClass：${sc_name}"
        local current_defaults
        current_defaults=$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
        if [ -n "${current_defaults}" ]; then
            while read -r sc; do
                if [ -n "${sc}" ] && [ "${sc}" != "${sc_name}" ]; then
                    kubectl patch storageclass "${sc}" -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' >/dev/null 2>&1 || true
                fi
            done <<<"${current_defaults}"
        fi
        kubectl patch storageclass "${sc_name}" -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}' >/dev/null
    fi

    echo "==== StorageClass 列表 ===="
    kubectl get storageclass || true
    echo "==== [部署 NFS 动态 StorageClass] 结束 ===="
}

post_config_wizard() {
    echo "==== [控制面后置配置向导] 开始 ===="
    ensure_kubectl_ready || return 1

    echo "==== 节点列表 ===="
    kubectl get node -o wide || true

    echo
    if ask_yes_no "是否配置 Traefik 固定到入口节点标签（并可选 NodePort）？" "y"; then
        configure_traefik_for_ingress_nodes
    else
        echo "已跳过 Traefik 配置。"
    fi

    echo
    if ask_yes_no "是否部署 NFS 动态 StorageClass（nfs-subdir-external-provisioner）？" "y"; then
        deploy_nfs_dynamic_storage
    else
        echo "已跳过 NFS 动态存储部署。"
    fi

    echo
    echo "==== 快速检查 ===="
    kubectl get node -o wide || true
    kubectl get storageclass 2>/dev/null || true
    kubectl -n kube-system get pod -o wide | head -n 80 || true

    echo "==== [控制面后置配置向导] 结束 ===="
}

cluster_quick_check() {
    echo "==== [集群快速检查] 开始 ===="
    ensure_kubectl_ready || return 1
    kubectl get node -o wide || true
    echo
    kubectl get storageclass || true
    echo
    kubectl -n kube-system get pod -o wide || true
    echo "==== [集群快速检查] 结束 ===="
}

show_menu() {
    cat <<'EOF'
========================================
  k3s 通用部署助手（交互式）
========================================
请选择当前机器要执行的操作：

  1) 通用初始化（所有节点建议先执行）
  2) 配置 NFS 存储服务器（可选）
  3) 安装 k3s server（首个控制面）
  4) 安装 k3s server（加入已有控制面）
  5) 安装 k3s agent（worker/入口等）
  6) 控制面后置配置向导（Traefik 固定入口 + NFS 动态 SC）
  7) 集群快速检查（需要 kubectl/kubeconfig）

  0) 退出
EOF
}

main() {
    require_root

    while true; do
        show_menu
        read -rp "请输入选项编号: " choice
        case "${choice}" in
            1) prepare_common ;;
            2) setup_nfs_server ;;
            3) install_k3s_server_first ;;
            4) install_k3s_server_join ;;
            5) install_k3s_agent ;;
            6) post_config_wizard ;;
            7) cluster_quick_check ;;
            0) echo "已退出。"; exit 0 ;;
            *) echo "无效选项：${choice}" ;;
        esac

        echo
        read -rp "按回车返回菜单，或 Ctrl+C 退出..." _
    done
}

main "$@"

