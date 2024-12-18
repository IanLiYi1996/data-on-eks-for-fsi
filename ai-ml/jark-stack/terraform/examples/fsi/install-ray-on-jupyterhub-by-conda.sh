#!/bin/bash
# Shell script to setup a conda environment named 'ray' with Python 3.8.13,
# and install ray==2.6.0, ipykernel, and configure the kernel for Jupyter.

# Exit on error
set -e

echo "Creating conda environment 'ray' with Python 3.8.13..."
conda create --yes --name ray python=3.8.13

# Activate the newly created environment
echo "Activating the conda environment 'ray'..."


# Install ray version 2.6.0
echo "Installing ray==2.6.0..."
/opt/conda/envs/ray/bin/python3 -m pip install ray==2.6.0

# Install ipykernel
echo "Installing ipykernel..."
/opt/conda/envs/ray/bin/python3 -m pip install ipykernel

# Install the IPython kernel into the current environment
echo "Registering the 'my-ray' kernel with Jupyter..."
/opt/conda/envs/ray/bin/python3 -m ipykernel install --user --name=my-ray --display-name "my-ray"

echo "Setup completed successfully."