# Automatic_Alpha_multimer
make the automatic script for large amount of complex for AlphaFold Multimer prediction

# Usage:
  $0 -i <input_fasta_or_dir> -o <archive_output_root> [options]

Required:
  -i    Input fasta file OR directory containing fasta files
  -o    Output archive root directory (recommended: network disk)

Optional:
  --local-root   Local temp root (default: /mnt/nvme)
  --db           ColabFold DB path (default: /mnt/nvme/colabfold_db/)
  --mmseqs       mmseqs binary path
                 (default: /home/ubuntu/localcolabfold/localcolabfold/conda/envs/colabfold/bin/mmseqs)
  --threads      Threads for colabfold_search (default: 15)
  --gpu          GPU id for colabfold_search (default: 1)

  --model-type   Model type for colabfold_batch (default: alphafold2_multimer_v3)
  --num-models   Number of models (default: 5)
  --num-recycles Number of recycles (default: 3)
  --pair-mode    Pair mode (default: unpaired_paired)
  --pair-strategy Pair strategy (default: greedy)
  --use-templates  Use templates in prediction (default: on)
  --no-templates   Disable templates

Examples:
  # Run all fasta files in a directory
  $0 -i /mnt/nvme/complexs -o /home/Ubuntu/archive

  # Run one fasta file
  $0 -i /mnt/nvme/complexs/complex1.fasta -o /home/Ubuntu/archive

  # Customize local temp root and gpu
  $0 -i ./complexs -o /home/Ubuntu/archive --local-root /mnt/nvme --gpu 0 --threads 20
