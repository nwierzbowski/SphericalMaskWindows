#!/bin/bash

# Determine Python command
if command -v python >/dev/null 2>&1; then
  PYTHON_CMD="python"
else
  PYTHON_CMD="python3"
fi

echo Preprocess data
$PYTHON_CMD prepare_data_inst_instance_stpls3d.py
