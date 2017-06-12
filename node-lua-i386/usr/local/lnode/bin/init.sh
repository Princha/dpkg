#!/usr/bin/env sh

# 在开机时运行恢复命令，保证 Node.lua 所有文件为最新版本

export NODELUA_ROOT=/tmp/lnode
mkdir -p ${NODELUA_ROOT}
rm -rf ${NODELUA_ROOT}/*

# update.zip 为最后下载的最新的更新包
if [ -f "/usr/local/lnode/update/update.zip" ]; then
	unzip /usr/local/lnode/update/update.zip -d ${NODELUA_ROOT}
	chmod 777 ${NODELUA_ROOT}/bin/*

	${NODELUA_ROOT}/bin/lnode ${NODELUA_ROOT}/bin/recovery ${NODELUA_ROOT}/
fi

# 启动应用管理进程

lpm start lhost

