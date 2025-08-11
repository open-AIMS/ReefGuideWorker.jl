julia -t auto --project=. -e "using Revise; using DotEnv; using Pkg; Pkg.develop(path=\"..\"); using ReefGuideWorker; DotEnv.load!();" -i
