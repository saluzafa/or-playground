#!/bin/bash

DEPLOY_MODE=Y npm run build
git subtree push --prefix dist origin gh-pages
