# VPS 自动测速 + 识别 + Telegram 推送脚本

## 效果展示，默认调用就近测速点

![image.png](https://img.lwxpz.me/file/1747821283307_image.png)
# 麻烦点个免费的 Star
![image.png](https://img.lwxpz.me/file/1747839668065_image.png)

## 下载脚本命令为

```
wget https://raw.githubusercontent.com/jc-lw/vpscesu/refs/heads/main/speedtest.sh && chmod +x /root/speedtest.sh
```

## 运行脚本命令为

```
bash speedtest.sh
```

```
/root/speedtest.sh
```
## 调用其他国家测速点
- 添加常用地区SERVER ID
- 支持：jp sg hk kr us tw
- 修改bash speedtest.sh -r “jp”为hk 即可
```
bash speedtest.sh -r jp
```
## 需要修改地方
- 添加 TG推送信息
- 群组或个人ID
- 机器人toke
![image.png](https://img.lwxpz.me/file/1747824579023_image.png)
