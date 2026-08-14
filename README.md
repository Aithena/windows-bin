1、安装 Git

2、将仓库克隆到本地 C:\Users\用户名\bin\

3、运行 Git

```
mkdir -p ~/bin
chmod +x ~/bin/tag
hash -r
tag -h
```

Git Bash 一般已经把 ~/bin 加进 PATH 了。如果提示找不到命令，把下面这行写进 ~/.bashrc：

```
export PATH="$HOME/bin:$PATH"
```

再执行 source ~/.bashrc。
