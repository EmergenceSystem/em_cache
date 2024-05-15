use actix_web::{post, App, HttpServer, HttpResponse, Responder};
use std::string::String;
use reqwest::Client;
use embryo::{Embryo, EmbryoList};
use serde_json::{from_str,to_string};
use serde::Serialize;
use std::collections::HashMap;
use redis::{AsyncCommands,Commands,RedisError};

/*
* this looks in the cache for the query and returns the results
*/
#[post("/query")]
async fn query_handler(body: String) -> impl Responder {
    let embryo_list : EmbryoList = generate_embryo_list(body).await;
    HttpResponse::Ok().json(embryo_list)
}

/*
* this gets a query + result tuple and stores it in the cache
* returns the key(query) of the stored tuple 
*/
#[post("/cache")]
async fn cache_handler(body: String) -> impl Responder {
    let last: HashMap<String,String> =  from_str(&body).expect("Error while parsing json");
    let query: String = last.get("query").unwrap().to_string();
    let result: EmbryoList = serde_json::from_str(last.get("results").unwrap()).expect("wrong results format");
    add_to_cache(query.clone(), result).await;
    HttpResponse::Ok().body(query)
}

async fn add_to_cache(query: String, results: EmbryoList) -> std::io::Result<()> {
    let client : redis::Client = redis::Client::open("redis://127.0.0.1:6379").unwrap();
    let mut con = client.get_async_connection().await.unwrap();
    con.set::<String,String, String>(query, serde_json::to_string(&results).unwrap()).await;
    Ok(())
}

async fn generate_embryo_list(json_string: String) -> EmbryoList {
    let search: HashMap<String,String> = from_str(&json_string).expect("Erreur lors de la désérialisation JSON");
    let client : redis::Client = redis::Client::open("redis://127.0.0.1").unwrap();
    let mut con = client.get_async_connection().await.unwrap();
    let wrapped_result:Result<String, RedisError> = con.get(search.get("query").unwrap()).await;
    let result = wrapped_result.unwrap();
    let em_list: EmbryoList = serde_json::from_str(&result).unwrap();
    em_list
}

#[actix_web::main]
async fn main() -> std::io::Result<()> {
    let client : redis::Client = redis::Client::open("redis://127.0.0.1:6379").unwrap();
    match em_filter::find_port().await {
        Some(port) => {
            let filter_url = format!("http://localhost:{}/query", port);
            println!("Filter registrer: {}", filter_url);
            em_filter::register_filter(&filter_url).await;
            HttpServer::new(|| App::new()
                .service(query_handler)
                .service(cache_handler))
                .bind(format!("127.0.0.1:{}", port))?.run().await?;
        },
        None => {
            println!("Can't start");
        },
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use actix_web::{http::header::ContentType, test, App,body::MessageBody, body::to_bytes};
    use std::collections::HashMap;
    use std::str;
    use embryo::{Embryo, EmbryoList};
    use super::*;

    #[actix_web::test]
    async fn test_cache_post() {

        let em_list = EmbryoList { embryo_list: vec![Embryo { properties: {HashMap::from([("url".to_string(), "https://www.speedtest.net/".to_string()), ("resume".to_string(), "Speedtest by Ookla is a global broadband speed test that lets you measure your internet performance on any device.".to_string())])} }, Embryo { properties: {HashMap::from([("resume".to_string(), "When you click the \"Show more info\" button, you can see your upload speed and connection latency (ping)".to_string()), ("url".to_string(), "https://fast.com/".to_string())])} }]};
        let app = test::init_service(App::new().service(cache_handler)).await;
        let query_str : String = "test".to_string();
        let param_map :HashMap<String,  String>= HashMap::from([("query".to_string(),query_str.clone()), ("results".to_string(), serde_json::to_string(&em_list).unwrap())]);
        let req = test::TestRequest::post().uri("/cache").set_json(param_map).to_request();
        let resp = test::call_service(&app, req).await;
        assert!(resp.status().is_success());
        let body = resp.into_body();
        assert_eq!(to_bytes(body).await.unwrap(), query_str.as_bytes());
    }

    #[actix_web::test]
    async fn test_query_post() {
        let em_list = EmbryoList { embryo_list: vec![Embryo { properties: {HashMap::from([("url".to_string(), "https://www.speedtest.net/".to_string()), ("resume".to_string(), "Speedtest by Ookla is a global broadband speed test that lets you measure your internet performance on any device.".to_string())])} }, Embryo { properties: {HashMap::from([("resume".to_string(), "When you click the \"Show more info\" button, you can see your upload speed and connection latency (ping)".to_string()), ("url".to_string(), "https://fast.com/".to_string())])} }]};
        let app = test::init_service(App::new().service(query_handler)).await;
        let param_map :HashMap<String,  String>= HashMap::from([("query".to_string(),"test".to_string())]);
        let req = test::TestRequest::post().uri("/query").set_json(param_map).to_request();
        let resp = test::call_service(&app, req).await;
        assert!(resp.status().is_success());
        let bytes_body = to_bytes(resp.into_body()).await.unwrap();
        let body = str::from_utf8(&bytes_body).unwrap();
        let ret_em : EmbryoList = serde_json::from_str(body).unwrap();
        assert_eq!(ret_em.embryo_list.len(), em_list.embryo_list.len());
    }

}
