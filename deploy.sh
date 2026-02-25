#!/bin/bash

DEPLOY_MODE=Y npm run build
git add .
git commit -m "deploy"
git push origin master
git subtree push --prefix dist origin gh-pages
