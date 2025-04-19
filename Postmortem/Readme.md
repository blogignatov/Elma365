**Postmortem: Инцидент с недоступностью приложения ELMA365 Prod, Test, Dev**

---

### 🕒 Временная хронология инцидента

- **08.04.2025 05:58** — Зафиксирована недоступность приложения ELMA365.
- **08.04.2025 07:51** — Сообщено, что ELMA365 недоступна.
- **08.04.2025 07:55** — Получена информация, что все три стенда ELMA365 не работают.
- **08.04.2025 07:58** — Подтверждено: причина — гипервизор Hyper-V, на котором размещены все виртуальные машины ELMA365 Prod,Test,Dev.
- **08.04.2025 09:26** — Инженеру по инфраструктуре приложения ELMA365 направлена информация о недоступности приложения.
- **08.04.2025 09:30** — Проверено, что сервер ELMA-MNG01 (с которого осуществляется доступ ко всем VM) недоступен.
- **08.04.2025 09:50** — Восстановлен доступ к гипервизору. Инженер был уведомлен.
- **08.04.2025 10:13** — kube-apiserver не запускается, креш при старте.
- **08.04.2025 10:18** — kube-apiserver не работает из-за недоступного ETCD.
- **08.04.2025 10:25** — Экземпляр ETCD не читает базу, файл поврежден.
- **08.04.2025 10:30** — Проверена доступность отдельных баз данных на отдельных VM: PostgreSQL, Mongo, S3.
- **08.04.2025 10:50** — Уточнение версии Deckhouse, попытка рестора ETCD.
- **08.04.2025 11:50** — ETCD запущен успешно.
- **08.04.2025 12:05** — kube-apiserver отвечает.
- **08.04.2025 12:15** — Все системные поды восстановлены.
- **08.04.2025 12:20** — В namespace elma365-prod отмечены сотни крешей и повторных деплойментов.
- **08.04.2025 12:35** — После падения ETCD Kubernetes считает, что поды не существуют, и создает их заново, получаются дубликаты.
- **08.04.2025 12:45** — `kubectl rollout restart deploy` в elma365-prod результатов не дает.
- **08.04.2025 12:55** — Запущен Helm-redеплой:
```bash
helm upgrade --install elma365 elma365/elma365 --version 2024.11.28 \
  -f values-elma365.yaml --timeout=30m --wait -n elma365-prod --create-namespace --debug
```
- **08.04.2025 13:25** — Redеплой не решил проблему. Удаление всех подов:
```bash
helm uninstall elma365 -n elma365-prod
helm uninstall elma365-dbs -n elma365-dbs
```
- **08.04.2025 13:35** — Установка на существующие БД:
```bash
helm upgrade --install elma365-dbs elma365/elma365-dbs -f values-elma365-dbs.yaml -n elma365-dbs --create-namespace
helm upgrade --install elma365 elma365/elma365 --version 2024.11.28 \
  -f values-elma365.yaml --timeout=30m --wait -n elma365-prod --create-namespace --debug
```
- **08.04.2025 14:10** — Установка завершена успешно. Проверка доступности ELMA365-prod.
- **08.04.2025 15:30** — Написание Postmortem.
- **08.04.2025 16:00** — Попытка восстановления Dev и Test среды.
- **08.04.2025 17:45** — ETCD восстановлен, выяснилось: в Test и Dev, помимо поврежденного ETCD, были повреждены базы данных.
- **08.04.2025 17:50** — Дана рекомендация быстрее поднять Dev и Test из бэкапа самих VM.

---

### 🚨 Причина
Физическая неисправность RAID-контроллера на гипервизоре Hyper-V привела к потере доступности всех виртуальных машин:

- Kubernetes (Prod, Test, Dev — все single-node)
- PostgreSQL - Prod
- MongoDB - Prod
- S3 хранилище - Prod

После запуска сервера не удалось сразу восстановить ETCD, из-за чего `kube-apiserver` крашился. 
После ручного восстановления ETCD из backup системные поды поднялись, но Kubernetes повторно создал множество подов, вызвав конфликты.

---

###  Что было сделано

- Восстановлен доступ к гипервизору
- Проверена доступность MongoDB, PostgreSQL, Redis, RabbitMQ, S3
- Восстановлены ETCD и `kube-apiserver`
- Очистка namespace-ов, `helm uninstall`
- Установка  Elma365 через `helm chart` на существующие БД: `elma365-dbs`, `elma365`

---

### 📌 Выводы и рекомендации

| Категория      | Действие                                                                 |
|----------------|--------------------------------------------------------------------------|
| Инфраструктура | Для защиты от подобных сбоев необходим отказоустойчивый кластер, распределённый по нескольким гипервизорам |

---

###  Диагностика и критическая ошибка ETCD
```bash
crictl ps -a | grep etcd
abf441d87d0eb       3496ce9ae3406       About a minute ago   Exited              etcd                                      100                 27d6b85f2e6cd       etcd-elma-test01
26f3df04ef3f0       e8c7c7a6901a9       14 hours ago         Exited              backup                                    0                   f7bcb0248130e       d8-etcd-backup-b5f5aba8a10bdd6e37805598d89823389-29067840-678zn
c487426544453       3496ce9ae3406       6 days ago           Exited              image-holder-etcd                         0                   e02fbe03c6f09       d8-control-plane-manager-fgghs
crictl logs abf441d87d0eb
```
Пример вывода:
```bash
abf441d87d0eb  etcd  Exited  "failed to find database snapshot file (snap: snapshot file doesn't exist)"
```

Ошибка
etcd не может найти snapshot-файл v3-базы:
```bash
/var/lib/etcd/member/snap/0000000006bb8132.snap.db
```
Из-за этого происходит panic и crash:
```bash
panic: failed to recover v3 backend from snapshot
```

---


# Чеклист восстановления ETCD
Восстановление кластера Kubernetes на базе Deckhouse после сбоя ETCD, при котором kubectl недоступен, 
а static pods продолжают управляться kubelet. 
Диагностика и возврат доступности control-plane через crictl, etcdctl, crane, journalctl.

#### Немного офтоп про логику
После сбоя ETCD 

— etcd — это база данных, где Kubernetes хранит всё: кластеры, поды, конфигурации, секреты и т.п.

Если etcd ломается (удалён, повреждён, недоступен) — вся логика Kubernetes "замирает",
т.к. контроллеры не могут читать/писать конфигурацию.


При котором kubectl недоступен
— kubectl — это CLI для управления Kubernetes, но он работает только при доступности API-сервера (kube-apiserver).

А API-сервер зависит от etcd, т.к. он без него не может отвечать на запросы.


👉 Поэтому, если etcd сломан, kubectl теряет доступ, так как кластер не может обслуживать его запросы.

"а static pods продолжают управляться kubelet"
— Это ключевой момент.


В Kubernetes есть static pods — это поды, которые запускаются не через API-сервер, а напрямую kubelet-ом, по конфигурационным YAML-файлам, 
хранящимся локально (обычно в /etc/kubernetes/manifests).


kubelet (локальный агент на каждом узле) не зависит напрямую от etcd — он читает YAML-файлы и запускает контейнеры, даже если весь кластер "лежит".

### Download and install etcdctl for server Kubernetes
```bash
curl -L https://github.com/etcd-io/etcd/releases/download/v3.5.17/etcd-v3.5.17-linux-amd64.tar.gz -o etcd.tar.gz
tar -xzf etcd.tar.gz --strip-components=1 etcd-v3.5.17-linux-amd64/etcdctl
cp /root/deckhouse/recovery-etcd/etcdctl /usr/local/bin/
chmod +x /usr/local/bin/etcdctl
which etcdctl
etcdctl version
```

### 1. Предварительная диагностика состояния узла
Проверка состояния kubelet и наличия static pod'ов:
```bash
systemctl status kubelet
journalctl -u kubelet -f
journalctl -u kubelet -xe | grep etcd
ls -l /etc/kubernetes/manifests/
```
### 2. Диагностика состояния control-plane без kubectl
Проверка контейнеров и логов ETCD, apiserver, Deckhouse:
```bash
crictl ps -a | grep kube-apiserver
crictl logs <APISERVER_CONTAINER_ID>
crictl ps -a | grep etcd
crictl logs <ETCD_CONTAINER_ID>
crictl ps -a | grep deckhouse
crictl logs <DECKHOUSE_CONTAINER_ID>
crictl images | grep deckhouse
crictl inspect <CONTAINER_ID> | grep imageRef
```
### 3. Проверка и подготовка резервных копий etcd
Проверка наличия snapshot и архива, отключение etcd:
```bash
ls -lh /var/backups/etcd/
ls -lh /var/lib/etcd/etcd-backup.tar.gz
tar -xzf /var/lib/etcd/etcd-backup.tar.gz
mv /etc/kubernetes/manifests/etcd.yaml /root/deckhouse/recovery-etcdcli/etcd.yaml
cp -r /var/lib/etcd/member /var/lib/deckhouse-etcd-backup
rm -rf /var/lib/etcd/member
ls -lh ~/etcd-backup.snapshot
```
### 4. Восстановление etcd из snapshot
```bash
ETCDCTL_API=3 etcdctl snapshot restore /root/recovery-etcdcli/etcd-backup.snapshot \
  --name elma-prod01 \
  --initial-cluster elma-prod01=https://192.168.175.12:2380 \
  --initial-advertise-peer-urls https://192.168.175.12:2380 \
  --data-dir /var/lib/etcd
```
### 5. Возврат etcd в kubelet и проверка запуска
Возврат манифеста и перезапуск службы:
```bash
cp /root/deckhouse/recovery-etcdcli/etcd.yaml /etc/kubernetes/manifests/etcd.yaml
systemctl restart kubelet
crictl ps | grep etcd
crictl logs -f $(crictl ps | grep etcd | awk '{print $1}')
```
### 6. Проверка доступности ETCD и кластера
Проверка состояния etcd и API:
```bash
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key endpoint health
  ```
  Проверка доступность pod'ов
  ```bash
kubectl get po -A
 ```


### Рекомендуемый порядок восстановления
- Отключить etcd из запуска (mv etcd.yaml)
- Подготовить snapshot и очистить каталог /var/lib/etcd
- Выполнить etcdctl snapshot restore
- Вернуть etcd.yaml и перезапустить kubelet
- Проверить логи через crictl logs, убедиться в здоровье etcd
- Проверить kubectl, доступность pod'ов

