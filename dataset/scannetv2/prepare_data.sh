#!/bin/bash

# Determine Python command
if command -v python >/dev/null 2>&1; then
  PYTHON_CMD="python"
else
  PYTHON_CMD="python3"
fi

echo Copy data
$PYTHON_CMD split_data.py
echo Preprocess data
$PYTHON_CMD prepare_data_inst.py --data_split train
$PYTHON_CMD prepare_data_inst.py --data_split val
$PYTHON_CMD prepare_data_inst.py --data_split test
$PYTHON_CMD prepare_superpoint.py