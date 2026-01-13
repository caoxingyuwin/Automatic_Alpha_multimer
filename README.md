# Automatic_Alpha_multimer
make the automatic script for large amount of complex for Alpha Multimer prediction

# usuage
1）输入整个文件夹（推荐）
./run_alphamultimer.sh -i /mnt/nvme/complexs -o /home/Ubuntu/archive

2）输入单个文件（调试）
./run_alphamultimer.sh -i /mnt/nvme/complexs/complex1.fasta -o /home/Ubuntu/archive

3）自定义本地临时根目录 / 线程 / GPU
./run_alphamultimer.sh \
  -i /mnt/nvme/complexs \
  -o /home/Ubuntu/archive \
  --local-root /mnt/nvme \
  --threads 20 \
  --gpu 0
