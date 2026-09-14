// SPDX-License-Identifier: AGPL-3.0-only

package api

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/grafana/grafana/pkg/components/simplejson"
	"github.com/grafana/grafana/pkg/infra/tracing"
	"github.com/grafana/grafana/pkg/plugins"
	"github.com/grafana/grafana/pkg/plugins/manager/pluginfakes"
	contextmodel "github.com/grafana/grafana/pkg/services/contexthandler/model"
	"github.com/grafana/grafana/pkg/services/datasources"
	datafakes "github.com/grafana/grafana/pkg/services/datasources/fakes"
	"github.com/grafana/grafana/pkg/services/pluginsintegration/pluginstore"
	"github.com/grafana/grafana/pkg/services/user"
	"github.com/grafana/grafana/pkg/setting"
	"github.com/grafana/grafana/pkg/web"
)

func TestHTTPServer_GetFSDataSources_SQLDatabaseAliases(t *testing.T) {
	for _, pluginID := range []string{datasources.DS_POSTGRES, datasources.DS_MYSQL, datasources.DS_MSSQL} {
		t.Run(pluginID, func(t *testing.T) {
			for _, storedType := range []string{pluginID, "legacy-sql-alias"} {
				if pluginID == datasources.DS_POSTGRES && storedType != pluginID {
					storedType = "postgres"
				}
				t.Run(storedType, func(t *testing.T) {
					tests := []struct {
						name     string
						jsonData *simplejson.Json
						want     string
					}{
						{name: "nil jsonData", want: "legacy_database"},
						{name: "missing database", jsonData: simplejson.New(), want: "legacy_database"},
						{name: "empty database", jsonData: simplejson.NewFromAny(map[string]any{"database": ""}), want: "legacy_database"},
						{name: "null database", jsonData: simplejson.NewFromAny(map[string]any{"database": nil}), want: "legacy_database"},
						{name: "preserves configured database", jsonData: simplejson.NewFromAny(map[string]any{"database": "configured_database"}), want: "configured_database"},
					}
					for _, tc := range tests {
						t.Run(tc.name, func(t *testing.T) {
							ds := &datasources.DataSource{
								OrgID:    1,
								UID:      "sql-source",
								Name:     "SQL source",
								Type:     storedType,
								Database: "legacy_database",
								JsonData: tc.jsonData,
							}
							plugin := pluginstore.Plugin{
								JSONData: plugins.JSONData{
									ID:       pluginID,
									Type:     plugins.TypeDataSource,
									AliasIDs: []string{storedType},
								},
								FS: &pluginfakes.FakePluginFS{},
							}
							hs := &HTTPServer{
								Cfg:                setting.NewCfg(),
								tracer:             tracing.InitializeTracerForTest(),
								pluginStore:        &pluginstore.FakePluginStore{},
								pluginAssets:       newPluginAssets()(),
								DataSourcesService: &datafakes.FakeDataSourceService{DataSources: []*datasources.DataSource{ds}},
							}
							ctx := &contextmodel.ReqContext{
								Context:      &web.Context{Req: httptest.NewRequest(http.MethodGet, "/api/frontend/settings", nil)},
								SignedInUser: &user.SignedInUser{OrgID: 1},
								// Permission filtering is independent of datasource normalization.
								PublicDashboardAccessToken: "test-token",
							}
							available := AvailablePlugins{
								plugins.TypeDataSource: {pluginID: &availablePluginDTO{Plugin: plugin}},
							}

							settings, err := hs.getFSDataSources(ctx, available)

							require.NoError(t, err)
							require.Equal(t, pluginID, settings[ds.Name].Type)
							require.Equal(t, tc.want, settings[ds.Name].JSONData["database"], "SQL database normalization must preserve the configured database")
						})
					}
				})
			}
		})
	}
}
