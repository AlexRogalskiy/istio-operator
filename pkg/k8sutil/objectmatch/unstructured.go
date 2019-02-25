/*
Copyright 2019 Banzai Cloud.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package objectmatch

import (
	"encoding/json"

	"github.com/goph/emperror"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

type UnstructuredMatcher struct{}

// Match compares two unstructured.Unstructured objects
func (m UnstructuredMatcher) Match(old, new *unstructured.Unstructured) (bool, error) {
	oldData, err := json.Marshal(old)
	if err != nil {
		return false, emperror.Wrap(err, "could not marshal object")
	}
	newData, err := json.Marshal(new)
	if err != nil {
		return false, emperror.Wrap(err, "could not marshal object")
	}

	matched, err := match(oldData, newData, new)
	if err != nil {
		return false, emperror.Wrap(err, "could not match objects")
	}

	return matched, nil
}
