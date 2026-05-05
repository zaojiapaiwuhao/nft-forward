# nft-forward
基于 nftables 的 Linux 端口转发管理脚本，支持域名解析和自动定时重载。

# nft-forward

基于 `nftables` 的 Linux 端口转发管理脚本，支持域名解析和自动定时重载。

## 功能特性

- 支持单端口转发
- 支持多端口一一对应转发
- 支持 TCP / UDP 同时转发
- 支持 IPv4 目标地址
- 支持域名目标地址
- 支持手动重新解析域名并重载规则
- 支持 systemd timer 自动定时重新解析域名
- 支持批量导入规则
- 支持备注
- 支持规则查看、删除、清空
- 支持安装初始化 nftables
- 支持开启 IPv4 转发
- 可选开启 BBR + fq
- 支持诊断 / 自检
- 支持卸载本工具配置并删除脚本

## 系统要求

- Linux
- Bash 4+
- root 权限
- nftables
- systemd，可选，用于自动定时重载
- iproute2，通常系统自带

支持的包管理器：

- apt
- dnf
- yum
- pacman

## 安装

下载脚本：

```bash
wget https://raw.githubusercontent.com/zaojiapaiwuhao/nft-forward/main/nft.sh

chmod +x nft.sh
sudo ./nft.sh


1) 安装 / 初始化 nftables
2) 查看现有端口转发
3) 新增端口转发
4) 删除端口转发
5) 一键清空所有转发
6) 批量导入转发规则
7) 诊断 / 自检
8) 域名解析 / 规则重载
9) 卸载本工具配置并删除脚本
10) 退出脚本

安全说明

本脚本需要 root 权限运行。
本脚本会启用 IPv4 forwarding。
本脚本仅管理 table ip port_forward。
不要把真实服务器上的规则数据文件上传到公开仓库。
不要在备注里填写密码、token、密钥等敏感信息。
数据文件和配置文件默认使用较严格权限。
卸载功能会删除本工具创建的 nftables 表、配置文件、数据文件、日志、systemd timer/service，以及当前脚本自身。

SNAT 说明
本工具默认会对转发流量做 DNAT，并在 postrouting 阶段 SNAT 到本机 IPv4 地址。
这适合大多数“中转机端口转发”场景。
如果希望目标服务器看到真实客户端 IP，则不能简单使用 SNAT，需要目标服务器具备正确回程路由，或者使用更复杂的路由策略。
