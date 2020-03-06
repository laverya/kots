package cli

import (
	"os"
	"path/filepath"
	"strings"

	"github.com/pkg/errors"
	"k8s.io/cli-runtime/pkg/genericclioptions"
)

var (
	kubernetesConfigFlags *genericclioptions.ConfigFlags
)

func ExpandDir(input string) string {
	if strings.HasPrefix(input, "~") {
		input = filepath.Join(homeDir(), strings.TrimPrefix(input, "~"))
	}

	uploadPath, err := filepath.Abs(input)
	if err != nil {
		panic(errors.Wrapf(err, "unable to expand %q to absolute path", input))
	}

	return uploadPath
}

func homeDir() string {
	if h := os.Getenv("HOME"); h != "" {
		return h
	}
	return os.Getenv("USERPROFILE")
}
