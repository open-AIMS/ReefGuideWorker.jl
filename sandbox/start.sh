julia -t auto --project=. -e "using Revise; using DotEnv; using ReefGuideWorker; DotEnv.load!(); ReefGuideWorker.start_worker();" -i
