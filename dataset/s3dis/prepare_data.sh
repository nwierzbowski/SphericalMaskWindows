#!/bin/bash

# Determine Python command
if command -v python >/dev/null 2>&1; then
  PYTHON_CMD="python"
else
  PYTHON_CMD="python3"
fi

echo Prepare raw data
$PYTHON_CMD prepare_s3dis.py
echo Prepare superpoints
$PYTHON_CMD prepare_superpoints.py