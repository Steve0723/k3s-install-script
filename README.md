# k3s 通用部署说明（配合 `k3s_setup.sh`）

这份说明不绑定任何特定节点/地域，你可以把它用在任意“多机 + 内网互通”的环境里（如 easytier / wireguard / tailscale）。

## 你将得到什么

- 一套交互式脚本：`k3s_setup.sh`
- 支持：
  - 通用初始化（swap/内核参数/依赖）
  - 安装 `k3s server`（首个控制面，可选 embedded etcd `--cluster-init`）
  - 安装 `k3s server`（加入已有控制面）
  - 安装 `k3s agent`（可选标记为入口节点 `ingress=true`）
  - 控制面后置配置向导：
    - Traefik 固定到入口节点标签（可选 NodePort）
    - NFS 动态 StorageClass（RWX）

## 推荐安装顺序

1. 所有将加入集群的节点：执行脚本菜单 `1`（通用初始化）
2. （可选）存储机：执行菜单 `2`（配置 NFS）
3. 任选一台作为首个控制面：执行菜单 `3`（安装 `k3s server`）
4. （可选）追加控制面：在另一台机器执行菜单 `4`（加入控制面）
5. 其余机器：执行菜单 `5`（安装 `k3s agent`）
6. 在任一 `k3s server` 上：执行菜单 `6`（后置配置向导）

## Ingress 是什么（简述）

Ingress 可以理解为“集群统一入口的反向代理规则”，常见用法是按域名/路径把请求转发到不同服务。  
k3s 默认 Ingress Controller 是 Traefik。

脚本支持把 Traefik 固定到入口节点（通过节点标签选择），并推荐用 **NodePort** 暴露（避免占用机器的 80/443，便于你在入口机上继续跑 Nginx/Caddy 做反代/加速）。

## 存储怎么选（数据库/面板）

脚本提供两类思路：

- **NFS 动态 StorageClass（RWX）**：适合共享文件、练习、多副本同时读写
- **local-path（RWO）**：更适合数据库（延迟更低、抖动更小）；通常配合 `nodeSelector/affinity` 把 DB 固定到某个节点

建议：把 `local-path` 作为默认存储，把 NFS 作为“共享/RWX 补充”。

## 多控制面注意事项（embedded etcd）

embedded etcd 对网络延迟与抖动敏感：

- 推荐：控制面节点尽量在同地域/低延迟网络
- 跨地域：更适合学习/实验，出现控制面抖动属于常见现象

## 常见排查点

- 节点 `NotReady`：确认安装时 `--node-ip` 是内网 IP；必要时指定 `--flannel-iface` 到你的 overlay 网卡
- Traefik 没跑到入口节点：确保入口节点有标签 `ingress=true`（或你配置的标签），并在 server 上重跑菜单 `6`
- NFS PVC 一直 Pending：确认 NFS 网段/端口可达、客户端已装 `nfs-common`、NFS 导出目录权限正确

