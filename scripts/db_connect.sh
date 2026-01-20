#!/bin/bash

# Database connection script
echo "Connecting to database..."
mysql -h __DB_HOST__ -u __DB_USER__ -p__DB_PASSWORD__ __DB_NAME__